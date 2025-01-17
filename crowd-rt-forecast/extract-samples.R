# Packages -----------------------------------------------
library(covid.ecdc.forecasts)
library(googledrive)
library(googlesheets4)
library(dplyr)
library(purrr)
library(tidyr)
library(data.table)
library(lubridate)
library(zoo)
library(scoringutils)
library(ggplot2)
library(here)

# Google sheets authentification -----------------------------------------------
google_auth()

spread_sheet <- "1g4OBCcDGHn_li01R8xbZ4PFNKQmV-SHSXFlv2Qv79Ks"
identification_sheet <- "1GJ5BNcN1UfAlZSkYwgr1-AxgsVA2wtwQ9bRwZ64ZXRQ"

# setup ------------------------------------------------------------------------
# - 1 as this is usually updated on a Tuesday
submission_date <- latest_weekday()
median_ensemble <- FALSE

# load data from Google Sheets -------------------------------------------------
ids <- try_and_wait(read_sheet(ss = identification_sheet, sheet = "ids"))
forecasts <- try_and_wait(read_sheet(ss = spread_sheet))

names_ids <- ids %>%
	dplyr::select(c(forecaster_id, board_name)) %>%
	unique()

delete_data <- FALSE
if (delete_data) {
  # add forecasts to backup sheet
  try_and_wait(sheet_append(ss = spread_sheet, sheet = "oldforecasts",
               data = forecasts))

  # delete data from sheet
  cols <- data.frame(matrix(ncol = ncol(forecasts), nrow = 0))
  names(cols) <- names(forecasts)
  try_and_wait(write_sheet(data = cols, ss = spread_sheet,
                           sheet = "predictions"))
}

# obtain raw and filtered forecasts, save raw forecasts-------------------------
raw_forecasts <- forecasts %>%
  mutate(forecast_date = as.Date(forecast_date),
         submission_date = as.Date(submission_date))

# use only the latest forecast from a given forecaster
filtered_forecasts <- raw_forecasts %>%
  # interesting question whether or not to include foracast_type here.
  # if someone reconnecs and then accidentally resubmits under a different
  # condition should that be removed or not?
  group_by(forecaster_id, region) %>%
  filter(forecast_time == max(forecast_time)) %>%
  ungroup()

# replace forecast duration with exact data about forecast date and time
# define function to do this for raw and filtered forecasts
# seems like a duplicate - function for crowdforecastr?
replace_date_and_time <- function(forecasts) {
  forecast_times <- forecasts %>%
    group_by(forecaster_id, region) %>%
    summarise(forecast_time = unique(forecast_time)) %>%
    ungroup() %>%
    arrange(forecaster_id, forecast_time) %>%
    group_by(forecaster_id) %>%
    mutate(forecast_duration = c(NA, diff(forecast_time))) %>%
    ungroup()

  forecasts <- inner_join(
      forecasts, forecast_times,
      by = c("forecaster_id", "region", "forecast_time")
    ) %>%
    mutate(forecast_week = epiweek(forecast_date),
                  target_end_date = as.Date(target_end_date)) %>%
    select(-forecast_time)
  return(forecasts)
}

# replace time with duration and date with epiweek
raw_forecasts <- replace_date_and_time(raw_forecasts)
filtered_forecasts <- replace_date_and_time(filtered_forecasts)

# write raw forecasts
fwrite(raw_forecasts,
       here("crowd-rt-forecast", "raw-forecast-data",
            paste0(submission_date, "-raw-forecasts.csv")))

# draw samples from the distributions ------------------------------------------
draw_samples <- function(distribution, median, width, n_people = 1,
                         overall_sample_number = 1000,
                         min_per_person_samples = 50) {
  num_samples <- max(
    ceiling(overall_sample_number / n_people), min_per_person_samples
    )
  if (distribution == "log-normal") {
    values <- exp(rnorm(
      num_samples, mean = log(as.numeric(median)), sd = as.numeric(width))
      )
  } else if (distribution == "normal") {
    values <- rnorm(
      num_samples, mean = (as.numeric(median)), sd = as.numeric(width)
      )
  } else if (distribution == "cubic-normal") {
    values <- (rnorm(
      num_samples, mean = (as.numeric(median) ^ (1 / 3)), sd = as.numeric(width)
      )) ^ 3
  } else if (distribution == "fifth-power-normal") {
    values <- (rnorm(
      num_samples, mean = (as.numeric(median) ^ (1 / 5)), sd = as.numeric(width)
      )) ^ 5
  } else if (distribution == "seventh-power-normal") {
    values <- (rnorm(
      num_samples, mean = (as.numeric(median) ^ (1 / 7)), sd = as.numeric(width)
      )) ^ 7
  }
  out <- list(sort(values))
  return(out)
}

n_people <- filtered_forecasts %>%
  group_by(region) %>%
  summarise(n_ids = length(unique(forecaster_id))) %>%
  pull(n_ids) %>%
  min()

overall_sample_number <- 1000

# draw samples
forecast_samples <- filtered_forecasts %>%
  rename(location = region) %>%
  select(forecaster_id, location, target_end_date, submission_date,
         distribution, median, width) %>%
  arrange(forecaster_id, location, target_end_date) %>%
  rowwise() %>%
  mutate(
    value = draw_samples(median = median, width = width,
                         distribution = distribution,
                         n_people = 1, # draw 1000 samples per person
                         overall_sample_number = overall_sample_number,
                         min_per_person_samples = 50),
    sample = list(seq_len(length(value)))
    ) %>%
  unnest(cols = c(sample, value)) %>%
  ungroup() %>%
  select(forecaster_id, location, target_end_date, submission_date,
	 sample, value) %>%
  arrange(forecaster_id, location, target_end_date, sample)

# interpolate missing days
# I'm pretty sure the horizon time indexing is currently wrong.
dates <- unique(forecast_samples$target_end_date)
date_range <- seq(min(as.Date(min(dates))),
                  max(as.Date(max(dates))), by = "days")
submission_date <- unique(forecast_samples$submission_date)
forecaster_ids <- unique(forecast_samples$forecaster_id)
n_samples <- max(forecast_samples$sample)
helper_data <- expand.grid(target_end_date = date_range,
                           forecaster_id = forecaster_ids,
                           location = locations$location_name,
                           submission_date = submission_date,
                           sample = 1:n_samples)

forecast_samples_daily <- forecast_samples %>%
  mutate(target_end_date = as.Date(target_end_date)) %>%
  full_join(helper_data) %>%
  arrange(forecaster_id, location, sample, target_end_date) %>%
  group_by(forecaster_id, location, sample) %>%
  mutate(no_predictions = ifelse(all(is.na(value)), TRUE, FALSE)) %>%
  filter(!no_predictions) %>%
  mutate(value = na.approx(value))

forecast_samples_daily <- dplyr::left_join(
	forecast_samples_daily, 
	names_ids, 
	by = "forecaster_id"
)

# save forecasts in quantile-format
fwrite(forecast_samples_daily %>% 
         mutate(submission_date = submission_date, 
                target_type = "case"),
       here("crowd-rt-forecast", "forecast-sample-data",
            paste0(submission_date, "-forecast-sample-data.csv")))

# check results and plot
check <- forecast_samples_daily %>%
  rename(prediction = value) %>%
  sample_to_quantile() %>%
  mutate(target_end_date = as.Date(target_end_date))

plot <- plot_predictions(
  check %>% mutate(true_value = NA_real_,
  target_end_date = as.Date(target_end_date, origin = "1970-01-01")),
  x = "target_end_date",
  facet_formula = ~ forecaster_id + location
  )

plot_dir <- here("crowd-rt-forecast", "data", "plots", submission_date)
check_dir(plot_dir)
ggsave(file.path(plot_dir, "rt.png"))
