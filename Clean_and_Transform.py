"""
Athlete Performance & Wellness Monitoring - Cleaning & Transformation Pipeline
--------------------------------------------------------------------------------
Cleans the 4 raw CSVs and produces analysis-ready tables, including the
Acute:Chronic Workload Ratio (ACWR) - a real sports-science metric used to
flag injury risk (7-day rolling load / 28-day rolling load).

ACWR interpretation (Gabbett, 2016 - widely used in sports science):
  < 0.8   : undertraining (detraining risk)
  0.8-1.3 : "sweet spot" - optimal load
  1.3-1.5 : elevated injury risk
  > 1.5   : high injury risk (sharp load spike)

Outputs:
  athletes_clean.csv
  wellness_checkins_clean.csv
  training_load_clean.csv        (includes daily_load, acwr, risk_flag)
  injury_log_clean.csv
  cleaning_audit_log.txt
"""

import pandas as pd
import numpy as np
import re
import logging

logging.basicConfig(
    filename="cleaning_audit_log.txt",
    filemode="w",
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s"
)
log = logging.getLogger()


def parse_mixed_date(series: pd.Series) -> pd.Series:
    """Parse a column containing a mix of exactly 3 known, individually
    unambiguous date formats. Tries each explicit format in turn rather
    than relying on pandas' format='mixed' inference, which has known
    edge cases (it can mis-swap day/month even on unambiguous ISO strings
    when dayfirst=True is set)."""
    known_formats = ["%Y-%m-%d", "%d/%m/%Y", "%d-%b-%Y"]
    result = pd.Series(pd.NaT, index=series.index, dtype="datetime64[ns]")
    remaining = series.notna()
    for fmt in known_formats:
        if not remaining.any():
            break
        parsed = pd.to_datetime(series[remaining], format=fmt, errors="coerce")
        matched = parsed.notna()
        result.loc[parsed.index[matched]] = parsed[matched]
        remaining.loc[parsed.index[matched]] = False
    return result


# ----------------------------------------------------------------------
# 1. ATHLETES
# ----------------------------------------------------------------------
athletes = pd.read_csv("athletes_raw.csv")
before = len(athletes)

athletes["sport"] = athletes["sport"].astype(str).str.strip().str.title()
athletes["status"] = athletes["status"].replace("", np.nan).fillna("Unknown")
athletes["onboarding_date"] = parse_mixed_date(athletes["onboarding_date"])
athletes = athletes.drop_duplicates(subset="athlete_id", keep="first")

removed = before - len(athletes)
log.info(f"ATHLETES: removed {removed} duplicate rows (kept first occurrence).")
log.info(f"ATHLETES: standardized 'sport' casing on {before} rows.")

athletes.to_csv("athletes_clean.csv", index=False)

# ----------------------------------------------------------------------
# 2. WELLNESS CHECK-INS
# ----------------------------------------------------------------------
wellness = pd.read_csv("wellness_checkins_raw.csv")
before = len(wellness)

wellness["checkin_date"] = parse_mixed_date(wellness["checkin_date"])

# Fix unit inconsistency: sleep_value > 20 is almost certainly minutes, not hours
minute_mask = wellness["sleep_value"] > 20
n_fixed = minute_mask.sum()
wellness.loc[minute_mask, "sleep_hours"] = wellness.loc[minute_mask, "sleep_value"] / 60
wellness.loc[~minute_mask, "sleep_hours"] = wellness.loc[~minute_mask, "sleep_value"]
wellness = wellness.drop(columns=["sleep_value"])
log.info(f"WELLNESS: corrected {n_fixed} rows where sleep was recorded in minutes instead of hours.")

# Cap physiologically implausible resting HR (valid adult/adolescent athlete range ~35-100 bpm)
invalid_hr = ~wellness["resting_hr"].between(35, 100) & wellness["resting_hr"].notna()
log.info(f"WELLNESS: flagged {invalid_hr.sum()} implausible resting_hr values (set to NaN, e.g. 12, 220, -5, 999 bpm).")
wellness.loc[invalid_hr, "resting_hr"] = np.nan

# Impute small numbers of missing subjective scores with athlete-level median
for col in ["soreness_1_10", "fatigue_1_10", "mood_1_10", "resting_hr"]:
    n_missing = wellness[col].isna().sum()
    wellness[col] = wellness.groupby("athlete_id")[col].transform(lambda s: s.fillna(s.median()))
    log.info(f"WELLNESS: imputed {n_missing} missing '{col}' values with per-athlete median.")

wellness = wellness.dropna(subset=["checkin_date"])
wellness.to_csv("wellness_checkins_clean.csv", index=False)
log.info(f"WELLNESS: final row count {len(wellness)} (from {before} raw rows).")

# ----------------------------------------------------------------------
# 3. TRAINING LOAD + ACWR CALCULATION
# ----------------------------------------------------------------------
load = pd.read_csv("training_load_raw.csv")
before = len(load)

load["session_date"] = parse_mixed_date(load["session_date"])
load = load.dropna(subset=["session_date"])
load["daily_load"] = (load["session_rpe"] * load["duration_min"]).round(0)

# Sum multiple sessions per athlete per day, then build a complete daily calendar
daily = (
    load.groupby(["athlete_id", "session_date"])["daily_load"]
    .sum()
    .reset_index()
)

all_dates = pd.date_range(daily["session_date"].min(), daily["session_date"].max(), freq="D")
frames = []
for aid, grp in daily.groupby("athlete_id"):
    s = grp.set_index("session_date")["daily_load"].reindex(all_dates, fill_value=0)
    grp_full = s.rename_axis("session_date").reset_index(name="daily_load")
    grp_full["athlete_id"] = aid
    frames.append(grp_full)

daily_full = pd.concat(frames, ignore_index=True)

# ACWR = 7-day rolling avg load / 28-day rolling avg load (per athlete, chronological)
daily_full = daily_full.sort_values(["athlete_id", "session_date"])
daily_full["acute_7d"] = (
    daily_full.groupby("athlete_id")["daily_load"]
    .transform(lambda s: s.rolling(7, min_periods=1).mean())
)
daily_full["chronic_28d"] = (
    daily_full.groupby("athlete_id")["daily_load"]
    .transform(lambda s: s.rolling(28, min_periods=7).mean())
)
daily_full["acwr"] = (daily_full["acute_7d"] / daily_full["chronic_28d"]).round(2)


def risk_flag(acwr):
    if pd.isna(acwr):
        return "Insufficient Data"
    if acwr < 0.8:
        return "Undertraining"
    if acwr <= 1.3:
        return "Optimal"
    if acwr <= 1.5:
        return "Elevated Risk"
    return "High Risk"


daily_full["risk_flag"] = daily_full["acwr"].apply(risk_flag)

log.info(f"TRAINING LOAD: computed daily_load for {before} raw sessions.")
log.info(f"TRAINING LOAD: built ACWR (7d/28d rolling) time series across {daily_full['athlete_id'].nunique()} athletes, {len(daily_full)} athlete-days.")
log.info(f"TRAINING LOAD: risk flag distribution -> {daily_full['risk_flag'].value_counts().to_dict()}")

daily_full.to_csv("training_load_clean.csv", index=False)

# ----------------------------------------------------------------------
# 4. INJURY LOG
# ----------------------------------------------------------------------
injury = pd.read_csv("injury_log_raw.csv")
before = len(injury)

injury["injury_type"] = injury["injury_type"].astype(str).str.strip().str.title()
injury["onset_date"] = parse_mixed_date(injury["onset_date"])
injury["return_status"] = injury["return_status"].replace("", np.nan).fillna("Ongoing")
injury["days_missed"] = injury["days_missed"].clip(lower=1, upper=120)

log.info(f"INJURY LOG: standardized injury_type casing, parsed dates, filled {injury['return_status'].isna().sum()} blank statuses on {before} rows.")

injury.to_csv("injury_log_clean.csv", index=False)

print("Cleaning complete. Outputs:")
print("  athletes_clean.csv")
print("  wellness_checkins_clean.csv")
print("  training_load_clean.csv   (includes ACWR + risk_flag)")
print("  injury_log_clean.csv")
print("  cleaning_audit_log.txt")
