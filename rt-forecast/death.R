# Packages -----------------------------------------------------------------
library(covid.ecdc.forecasts)
library(EpiNow2, quietly = TRUE)
library(data.table, quietly = TRUE)
library(here, quietly = TRUE)
library(future, quietly = TRUE)
library(devtools, quietly = TRUE)
library(lubridate, quietly = TRUE)
library(ggplot2, quietly = TRUE)
library(purrr, quietly = TRUE)

# Set target date ---------------------------------------------------------
target_date <- latest_weekday(char = TRUE)

# Get observations --------------------------------------------------------
observations <- get_observations(dir = here("data-raw"), target_date)

# Get case forecasts ------------------------------------------------------
case_forecast <- suppressWarnings(
  get_regional_results(
    results_dir = here("rt-forecast", "data", "samples", "cases"),
    date = ymd(target_date), forecast = TRUE, samples = TRUE
  )$estimated_reported_cases$samples
)
case_forecast <- case_forecast[sample <= 1000]

# Forecast deaths from cases ----------------------------------------------
# set up parallel options
options(mc.cores = 4)
plan("multiprocess", workers = ceiling(availableCores() / 4))

# load the prototype regional_secondary function
source_gist("https://gist.github.com/seabbs/4dad3958ca8d83daca8f02b143d152e6")

# run across ECDC countries specifying
# options for estimate_secondary (EpiNow2)
forecast <- regional_secondary(
  observations, case_forecast,
  delays = delay_opts(list(
    mean = 2.5, mean_sd = 0.5,
    sd = 0.47, sd_sd = 0.2, max = 30
  )),
  return_fit = FALSE,
  secondary = secondary_opts(type = "incidence"),
  obs = obs_opts(scale = list(mean = 0.01, sd = 0.05), week_effect = FALSE),
  burn_in = as.integer(max(observations$date) - min(observations$date)) - 2 * 7,
  control = list(adapt_delta = 0.95, max_treedepth = 15),
  verbose = TRUE
)

# Save results to disk ----------------------------------------------------
samples_path <- here(
  "rt-forecast", "data", "samples", "deaths", target_date
  )
summarised_path <- here(
  "rt-forecast", "data", "summary", "deaths", target_date
  )
check_dir(samples_path)
check_dir(summarised_path)

# save summary and samples
fwrite(forecast$samples, file.path(samples_path, "samples.csv"))
fwrite(forecast$summarised, file.path(summarised_path, "summary.csv"))

# save plots
walk2(forecast$region, names(forecast$region), function(f, n) {
  walk(
    seq_len(length(f$plots)),
    ~ suppressMessages(ggsave(
      filename = paste0(n, "-", names(f$plots)[.], ".png"),
      plot = f$plots[[.]],
      path = paste0(samples_path, "/")
    ))
  )
})
