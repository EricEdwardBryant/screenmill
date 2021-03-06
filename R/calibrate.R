# ---- Calibrate Cropping ----
#' Calibrate cropping and rotation parameters
#'
#' This function calibrates plate cropping and rotation parameters for an image
#' with an arbritrarily sized grid of plates.
#'
#' @param dir Directory of images to process.
#' @param grid_rows Number of expected rows in colony grid.
#' @param grid_cols Number of expected columns in colony grid.
#' @param rotate A rough angle in degrees clockwise to rotate each plate. The
#' rotation angle will be further calibrated after applying this rotation.
#' Defaults to \code{90}.
#' @param range Range to explore (in degrees) when calibrating rotation angle.
#' Defaults to \code{2}.
#' @param thresh Fraction of foreground pixels needed to identify plate
#' boundaries when rough cropping. Defaults to \code{0.03}.
#' @param invert Should the image be inverted? Defaults to \code{TRUE}.
#' Recommended \code{TRUE} if colonies are darker than the plate.
#' @param default_crop If not \code{NULL} then use this dataframe as the
#' default crop coordinates.
#' @param overwrite Should existing crop calibration be overwritten?
#' Defaults to \code{FALSE}.
#' @param display Should cropped images be displayed for review?
#' Defaults to \code{TRUE}.
#' @param save_plate Should the calibrated plate be saved rather than
#' displayed (useful when calibrating many plates)? Defaults to \code{!display}.
#' @param colony_radius If <= 1, the box drawn around colonies will be this
#' fraction of half the average distance between rows and columns (Defaults to 1).
#' If > 1, the box will have a radius of this many pixels.
#' @param max_smooth Maximum number of pixels to allow when smoothing row and
#' column positions of individual colonies.
#'
#' @details
#' Crop calibration procedes through the following 3 steps:
#'
#' \enumerate{
#'   \item Rough crop
#'   \item Rotate
#'   \item Fine crop
#' }
#'
#' Rough cropping relies on high contrast between plates. If
#' \code{invert = TRUE} plates should be light and the region between plates
#' should be dark, and vice versa if \code{invert = FALSE}.
#'
#' Fine cropping finds the nearest object edge (problematic for plates without
#' any growth on the intended grid edges).
#'
#' @export

calibrate <- function(dir = '.', grid_rows, grid_cols,
                      rotate = 90, range = 2, thresh = 0.03, invert = TRUE,
                      rough_pad = c(0, 0, 0, 0), fine_pad = c(0, 0, 0, 0),
                      default_crop = NULL,
                      overwrite = FALSE, display = TRUE, save_plate = !display,
                      colony_radius = 1, max_smooth = 5) {

  status <- screenmill_status(dir)
  assert_that(
    is.number(rotate), is.number(range),
    is.number(thresh), is.flag(invert), is.flag(display), is.flag(save_plate),
    is.flag(overwrite), is.numeric(rough_pad), length(rough_pad) == 4,
    is.numeric(fine_pad), length(fine_pad) == 4
  )

  # Stop if plates have not yet been annotated
  if (!status$flag$annotated) {
    stop('Please annotate plates before cropping. See ?annotate for more details.')
  }

  if (!overwrite && status$flag$calibrated) {
    # Exit if already calibratd and no overwrite
    message('This batch has already been calibrated. Set "overwrite = TRUE" to re-calibrate.')
    return(invisible(status$dir))
  } else {
    # Remove pre-existing files
    suppressWarnings(file.remove(status$path$calibration_crop))
    suppressWarnings(file.remove(status$path$calibration_grid))
  }

  # Get paths to templates relative to dir, and corresponding plate positions
  annotation <-
    read_annotations(status$dir) %>%
    select(template, group, position, strain_collection_id, plate) %>%
    mutate(template = paste(status$dir, template, sep = '/')) %>%
    distinct

  key <- read_collection_keys(status$dir)

  templates <- unique(annotation$template)

  # Record start time
  time <- Sys.time()

  # Calibrate each template by iterating through templates and positions
  lapply(
    templates, calibrate_template,
    # Arguments
    annotation, key, grid_rows, grid_cols, thresh, invert, rough_pad,
    fine_pad, rotate, range, display,
    status$path$calibration_crop, status$path$calibration_grid,
    save_plate, default_crop, colony_radius, max_smooth
  )

  message('Finished calibration in ', format(round(Sys.time() - time, 2)))
  return(invisible(status$dir))
}

calibrate_addin <- function() {
  message('Choose a file in the directory of images you wish to process.')
  dir <- dirname(file.choose())
  calibrate(dir, overwrite = TRUE)
}

# ---- Utilities: calibrate ---------------------------------------------------
# Calibrate a single template image
#
# @param template path to template image
# @param annotation table of plate annotations
# @param thresh ? TODO currently used to detect rough crop locations
# @param invert Should the image be inverted
# @param rough_pad Padding around rough crop
# @param fine_pad Padding to add around fine crop
# @param rotate Rough rotation angle in degrees
# @param range Range of angles to explore in degrees
# @param display Should calibration be displayed
# @param crp path to crop calibration output
# @param grd path to grid calibration output
#
#' @importFrom readr write_csv
#' @importFrom tibble rownames_to_column

calibrate_template <- function(template, annotation, key, grid_rows, grid_cols, thresh, invert, rough_pad,
                               fine_pad, rotate, range, display, crp, grd, save_plate,
                               default_crop, colony_radius, max_smooth) {

  # Read image in greyscale format
  message('\n', basename(template), ': reading image and cropping plates')
  img <- screenmill:::read_greyscale(template)

  # Filter annotation data for this template
  anno <- annotation[which(annotation$template == template), ]

  if (is.null(default_crop)) {
    # Determine rough crop coordinates and apply to this image
    rough <- screenmill:::rough_crop(img, thresh, invert, rough_pad)
    rough$template <- basename(template)
  } else {
    rough <-
      default_crop[
        default_crop$template == basename(template),
        c('template', 'position', 'plate_row', 'plate_col', 'plate_x', 'plate_y',
          'rough_l', 'rough_r', 'rough_t', 'rough_b')]
  }

  if (nrow(rough) > length(anno$position)) warning('For ', basename(template), ', keeping positions (', paste(anno$position, collapse = ', '), ') of ', nrow(rough), ' available.\n', call. = FALSE)

  if (display) screenmill:::display_rough_crop(img, rough, 'red')

  plates <-
    lapply(1:length(anno$position), function(i) {
      p <- anno$position[i]
      with(rough[rough$position == p, ], img[ rough_l:rough_r, rough_t:rough_b ])
    })

  # Determine fine crop coordinates
  if (is.null(default_crop)) {
    progress <- dplyr::progress_estimated(length(anno$position))
    fine <-
      purrr::map_df(1:length(anno$position), function(i) {
        progress$tick()$print()
        p <- anno$position[i]
        result <- screenmill:::fine_crop(plates[[i]], rotate, range, fine_pad, invert, grid_rows, grid_cols)
        result$template <- basename(template)
        result$position <- p
        return(result)
      })
  } else {
    fine <-
      default_crop[
        default_crop$template == basename(template),
        c('template', 'position', 'rotate', 'fine_l', 'fine_r', 'fine_t', 'fine_b')]
  }

  # Combine rough and fine crop coordinates
  crop <-
    left_join(rough, fine, by = c('template', 'position')) %>%
    mutate(invert = invert) %>%
    select('template', 'position', everything())

  # Determine grid coordinates
  message('\n', basename(template), ': locating colony grid')
  progress <- progress_estimated(length(anno$position))
  grid <-
    map_df(1:length(anno$position), function(i) {
      progress$tick()$print()
      p                <- anno$position[i]
      collection_id    <- anno$strain_collection_id[i]
      collection_plate <- anno$plate[i]
      group            <- anno$group[i]
      finei            <- fine[which(fine$position == p), ]
      keyi  <- with(key, key[which(strain_collection_id == collection_id & plate == collection_plate), ])
      plate <- plates[[i]]

      if (invert) plate <- 1 - plate
      rotated <- EBImage::rotate(plate, finei$rotate)
      cropped <- with(finei, rotated[fine_l:fine_r, fine_t:fine_b])

      result <- screenmill:::locate_grid(cropped, grid_rows, grid_cols, radius = colony_radius, max_smooth = max_smooth)

      if (is.null(result)) {
        warning(
          'Failed to locate colony grid for ', basename(template),
          ' at position ', p, '. This plate position has been skipped.\n',
          call. = FALSE)
      } else {
        # Annotate result with template, position, strain collection and plate
        result <-
          mutate(result, template = basename(template), position = p) %>%
          left_join(mutate(anno, template = basename(template)), by = c('template', 'position'))

        # Check the grid size and compare to expected plate size
        replicates <- nrow(result) / nrow(keyi)

        if (sqrt(replicates) %% 1 != 0) {
          result <- NULL
          warning(
            'Size of detected colony grid (', nrow(result), ') for ',
            basename(template), ' at position ', p,
            ' is not a square multiple of the number of annotated positions (',
            nrow(keyi), ') present in the key for ', collection_id,
            ' plate #', collection_plate, '. This plate position has been skipped.\n', call. = FALSE
          )
        } else {
          # Annotate with key row/column/replicate values
          key_rows <- sort(unique(keyi$row))
          key_cols <- sort(unique(keyi$column))
          n_rows   <- length(key_rows)
          n_cols   <- length(key_cols)
          sqrt_rep <- sqrt(replicates)
          one_mat  <- matrix(rep(1, times = nrow(keyi)), nrow = n_rows, ncol = n_cols)

          rep_df <-
            (one_mat %x% matrix(1:replicates, byrow = T, ncol = sqrt_rep)) %>%
            as.data.frame %>%
            tibble::rownames_to_column('colony_row') %>%
            gather('colony_col', 'replicate', starts_with('V')) %>%
            mutate(
              colony_row = as.integer(colony_row),
              colony_col = as.integer(gsub('V', '', colony_col)),
              replicate  = as.integer(replicate)
            )

          col_df <-
            matrix(rep(key_cols, each = n_rows * replicates), ncol = n_cols * sqrt_rep) %>%
            as.data.frame %>%
            tibble::rownames_to_column('colony_row') %>%
            gather('colony_col', 'column', starts_with('V')) %>%
            mutate(
              colony_row = as.integer(colony_row),
              colony_col = as.integer(gsub('V', '', colony_col))
            )

          row_df <-
            matrix(rep(key_rows, each = n_cols * replicates), nrow = n_rows * sqrt_rep, byrow = T) %>%
            as.data.frame %>%
            tibble::rownames_to_column('colony_row') %>%
            gather('colony_col', 'row', starts_with('V')) %>%
            mutate(
              colony_row = as.integer(colony_row),
              colony_col = as.integer(gsub('V', '', colony_col))
            )

          result <-
            result %>%
            left_join(row_df, by = c('colony_row', 'colony_col')) %>%
            left_join(col_df, by = c('colony_row', 'colony_col')) %>%
            left_join(rep_df, by = c('colony_row', 'colony_col')) %>%
            select(template:replicate, colony_row:b, everything())
        }
      }

      if (display || save_plate) display_plate(cropped, result, template, group, p, text.color = 'red', grid.color = 'blue', save_plate)

      return(result)
    })

  if (nrow(grid) > 0) {
    grid$excluded <- FALSE
  } else {
    grid <- grid_empty()
  }

  # Write results to file
  write_csv(crop, crp, append = file.exists(crp))
  write_csv(grid, grd, append = file.exists(grd))
}

grid_empty <- function() {
  tibble::data_frame(
    template             = character(0),
    position             = integer(0),
    group                = integer(0),
    strain_collection_id = character(0),
    plate                = integer(0),
    row                  = integer(0),
    column               = integer(0),
    replicate            = integer(0),
    colony_row           = integer(0),
    colony_col           = integer(0),
    x                    = integer(0),
    y                    = integer(0),
    l                    = integer(0),
    r                    = integer(0),
    t                    = integer(0),
    b                    = integer(0),
    excluded             = logical(0)
  )
}


# ---- Display functions ------------------------------------------------------
display_rough_crop <- function(img, rough, color) {
  EBImage::display(img, method = 'raster')
  with(rough, segments(rough_l, rough_t, rough_r, rough_t, col = color))
  with(rough, segments(rough_l, rough_b, rough_r, rough_b, col = color))
  with(rough, segments(rough_l, rough_t, rough_l, rough_b, col = color))
  with(rough, segments(rough_r, rough_t, rough_r, rough_b, col = color))
  with(rough, text(plate_x, plate_y, position, col = color))
}

display_plate <- function(img, grid, template, group, position, text.color, grid.color, save_plate) {

  if (save_plate) {
    dir <- file.path(dirname(template), 'calibration', fsep = '/')
    if (!dir.exists(dir)) dir.create(dir)
    file <-
      paste0(
        stringr::str_pad(group, 3, side = 'left', pad = 0), '-',
        stringr::str_pad(position, 3, side = 'left', pad = 0), '-',
        gsub('\\.[^\\.]*$', '', basename(template)),
        '.png'
      )
    png(file.path(dir, file, fsep = '/'), width = 900, height = 600, bg = 'transparent')
  }

  EBImage::display(img, method = 'raster')

  if (!is.null(grid)) {
    with(grid, segments(l, t, r, t, col = grid.color))
    with(grid, segments(l, b, r, b, col = grid.color))
    with(grid, segments(l, t, l, b, col = grid.color))
    with(grid, segments(r, t, r, b, col = grid.color))
  }

  x <- nrow(img) / 2
  y <- ncol(img) / 2
  text(x, y, labels = paste(basename(template), paste('Group:', group), paste('Position:', position), sep = '\n'), col = text.color, cex = 1.5)

  if (save_plate) dev.off()
}

# ---- Locate Colony Grid -----------------------------------------------------
# Locate grid and determine background pixel intensity for a single image
#
# @param img An Image object or matrix. See \link[EBImage]{Image}.
# @param radius Fraction of the average distance between row/column centers and
# edges. Affects the size of the selection box for each colony.
#
#' @importFrom tidyr complete

locate_grid <- function(img, grid_rows, grid_cols, radius, max_smooth = 4) {

  # Scale image for rough object detection
  rescaled <- EBImage::normalize(img, inputRange = c(0.1, 0.8))

  # Blur image to combine spotted colonies into single objects for threshold
  blr <- EBImage::gblur(rescaled, sigma = 6)

  # Threshold using automatic background threshold level detection
  thr <- blr > EBImage::otsu(blr)

  # label objects using watershed algorithm to be robust to connected objects
  wat <- EBImage::watershed(EBImage::distmap(thr))

  # Characterize objects
  objs <- object_features(wat)

  # Exit if there are too few objects
  if (any(nrow(objs) < c(grid_rows, grid_cols))) return(NULL)

  # Identify row/column centers by clustering objects into into expected number
  clusters <-
    objs %>%
    mutate(
      x_cluster = cutree(hclust(dist(x)), k = grid_cols),
      y_cluster = cutree(hclust(dist(y)), k = grid_rows)
    )

  col_centers <- clusters %>% group_by(x_cluster) %>% summarise(x = median(x)) %>% pull(x) %>% sort()
  row_centers <- clusters %>% group_by(y_cluster) %>% summarise(y = median(y)) %>% pull(y) %>% sort()

  # Move break points to midpoint between centers
  rows <- head(row_centers, -1) + (diff(row_centers) / 2)
  cols <- head(col_centers, -1) + (diff(col_centers) / 2)

  # Clean up detected rows and columns
  cols <- remove_out_of_step(cols)
  rows <- remove_out_of_step(rows)
  cols <- add_missing_steps(cols)
  rows <- add_missing_steps(rows)

  if (length(cols) < 2 || length(rows) < 2) return(NULL)

  cols <- deal_with_edges(cols, n = length(cols) - grid_cols - 1, dim = nrow(wat))
  rows <- deal_with_edges(rows, n = length(rows) - grid_rows - 1, dim = ncol(wat))
  col_centers <- ((cols + lag(cols)) / 2)[-1]
  row_centers <- ((rows + lag(rows)) / 2)[-1]

  if (length(col_centers) < 1 || length(row_centers) < 1) return(NULL)

  # Characterize objects and bin them into rows/columns
  objs <-
    object_features(wat) %>%
    filter(eccen < 0.8) %>%
    mutate(
      colony_row = findInterval(y, rows),
      colony_col = findInterval(x, cols)
    ) %>%
    filter(colony_row >= 1L, colony_col >= 1L, colony_row <= grid_rows, colony_col <= grid_cols)

  # If multiple objects are found in a grid location, choose largest object
  rough_grid <-
    objs %>%
    group_by(colony_row, colony_col) %>%
    summarise(x = x[which.max(area)], y = y[which.max(area)]) %>%
    ungroup()

  # Determine x/y coordinates of each grid location
  fine_grid <-
    rough_grid %>%
    # Fill missing row/column combinations with NA
    complete(colony_row, colony_col) %>%
    # Determine row locations
    group_by(colony_row) %>%
    arrange(colony_col) %>%
    mutate(
      # If missing, use estimated center
      y = ifelse(is.na(y), row_centers[colony_row], y),
      y = if (n() < 10) y else round(predict(smooth.spline(c(0, colony_col, max(colony_col) + 1), c(median(y), y, median(y))), colony_col)[[2]]),
      y = ifelse(abs(y - median(y)) <= max_smooth, y, row_centers[colony_row])
    ) %>%
    # Determine column locations
    group_by(colony_col) %>%
    arrange(colony_row) %>%
    mutate(
      # If missing, use estimated center
      x = ifelse(is.na(x), col_centers[colony_col], x),
      x = if (n() < 10) x else round(predict(smooth.spline(c(0, colony_row, max(colony_row) + 1), c(median(x), x, median(y))), colony_row)[[2]]),
      x = ifelse(abs(x - median(x)) <= max_smooth, x, col_centers[colony_col])
    ) %>%
    ungroup

  # Add a selection box
  selection <-
    fine_grid %>%
    mutate(
      # Radius less than or equal to 1 will do fraction of average row and coulmn width, otherwise fixed
      # radius in pixel units is used
      radius = { if (radius <= 1) round(((mean(diff(rows)) + mean(diff(cols))) / 4) * radius) else radius },
      l = x - radius,
      r = x + radius,
      t = y - radius,
      b = y + radius,
      x = as.integer(x),
      y = as.integer(y),
      # Fix edges if radius is out of bounds of image
      l = as.integer(round(ifelse(l < 1, 1, l))),
      r = as.integer(round(ifelse(r > nrow(img), nrow(img), r))),
      t = as.integer(round(ifelse(t < 1, 1, t))),
      b = as.integer(round(ifelse(b > ncol(img), ncol(img), b)))
    )

  return(selection %>% select(colony_row, colony_col, x, y, l, r, t, b))
}

remove_out_of_step <- function(x) {
  step <- diff(x) / median(diff(x))
  remove <- which(abs(step - round(step)) > 0.2) + 1
  if (length(remove)) {
    x <- x[-remove]
    remove_out_of_step(x) # recursively remove until everything is in step
  } else {
    return(x)
  }
}

add_missing_steps <- function(centers) {
  steps   <- diff(centers)
  width   <- median(steps)
  missing <- which(steps > width * 1.25)
  add <- lapply(missing, function(x) {
    start <- centers[x]
    stop  <- centers[x + 1]
    seq(from = start + width, to = max(start + width, stop - (width * 0.6)), by = width)
  })
  sort(c(unlist(add), centers))
}

deal_with_edges <- function(x, n, dim) {
  if (n > 0) {
    # Remove the break that is more "out-of-step" with grid
    step <- abs(mean(diff(x)) - diff(x))
    if (head(step, 1) > tail(step, 1)) x <- tail(x, -1) else x <- head(x, -1)
    n <- n - 1
    x <- deal_with_edges(x, n, dim) # recurse until n == 0
  }
  if (n < 0) {
    # Add break to side furthest from edge
    if ((head(x, 1) - 1) > (dim - tail(x, 1))) {
      x <- c(max(1, head(x, 1) - mean(diff(x))), x)
    } else {
      x <- c(x, min(dim, tail(x, 1) + mean(diff(x))))
    }
    n <- n + 1
    x <- deal_with_edges(x, n, dim) # recurse until n == 0
  }
  return(x)
}

# ---- Display Calibration: TODO ----------------------------------------------
# Display crop calibration
#
# Convenience function for displaying crop calibrations. Usefull for viewing
# the result of manually edited
#
# @param dir Directory of images
# @param groups Cropping groups to display. Defaults to \code{NULL} which will
# display all groups.
# @param positions Positions to display. Defaults to \code{NULL} which will
# display all positions.
#
# @export

display_calibration <- function(dir = '.', groups = NULL, positions = NULL) {
  # only necessary for bug in EBImage < 4.13.7
  old <- par(no.readonly = TRUE)
  on.exit(par(old))

  # Find screenmill-annotations
  dir <- gsub('/$', '', dir)
  if (is.dir(dir)) {
    path <- paste(dir, 'screenmill-annotations.csv', sep = '/')
  } else {
    path <- dir
  }
  if (!file.exists(path)) {
    stop('Could not find ', path, '. Please annotate plates before cropping.
         See ?annotate for more details.')
  }

  calibration <- screenmill_annotations(path)
  if (!is.null(groups)) {
    calibration <- filter(calibration, group %in% c(0, groups))
  }
  if (!is.null(positions)) {
    calibration <- filter(calibration, position %in% c(0, positions))
  }

  files <- paste0(dir, '/', unique(calibration$template))
  for (file in files) {

    # Get data for file
    coords <- calibration[which(calibration$file == basename(file)), ]

    # Read as greyscale image
    img <- read_greyscale(file)

    # Apply Crop calibration
    lapply(1:nrow(coords), function(p) {
      rough   <- with(coords, img[ left[p]:right[p], top[p]:bot[p] ])
      rotated <- rotate(rough, coords$rotate[p])
      fine    <- with(coords, rotated[ fine_left[p]:fine_right[p], fine_top[p]:fine_bot[p] ])
      EBImage::display(fine, method = 'raster')
      x <- nrow(fine) / 2
      y <- ncol(fine) / 2
      text(x, y, labels = paste0('Group: ', coords$group[p], '\nPosition: ', coords$position[p]), col = 'red', cex = 1.5)
    })
  }
  return(invisible(dir))
}
