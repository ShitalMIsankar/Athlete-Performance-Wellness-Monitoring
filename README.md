# 🏅 Athlete Performance & Wellness Monitoring Analysis

An end-to-end analytics project simulating an athlete monitoring system for a multi-sport high-performance institute. It covers raw platform-style exports, Python cleaning, SQL risk analysis, and a Power BI dashboard design, centred on the **Acute:Chronic Workload Ratio (ACWR)**, a sports-science injury-risk metric.

![Python](https://img.shields.io/badge/Python-pandas%20%7C%20numpy-3776AB?logo=python&logoColor=white)
![SQL](https://img.shields.io/badge/SQL-MySQL-4479A1?logo=mysql&logoColor=white)
![Power BI](https://img.shields.io/badge/Power%20BI-DAX-F2C811?logo=powerbi&logoColor=black)

---

## 📌 Project Overview

| Item | Detail |
|---|---|
| Athletes | 180 (synthetic) across 8 sports |
| Sports | Athletics, Boxing, Archery, Weightlifting, Para Athletics, Wrestling, Badminton, Swimming |
| Monitoring window | 1 Oct 2025 – 31 Mar 2026 |
| Raw records | ~52K |
| Tools | Python (pandas, numpy), SQL (MySQL 8), Power BI (DAX) |

> **Note:** All data is synthetic and generated for portfolio purposes. No real athlete data is used.

---

## 📂 Repository Structure

```
├── 01_generate_raw_data.py        # Synthetic raw data generator (intentionally messy)
├── 02_clean_and_transform.py      # ETL pipeline + ACWR calculation
├── 03_sql_analysis.sql            # 18 analytical SQL queries
├── 04_powerbi_dashboard_guide.md  # 4-page dashboard build guide + DAX
├── 05_data_dictionary.md          # Column definitions for every table
├── cleaning_audit_log.txt         # Log of every cleaning decision
├── data/
│   ├── raw/                       # *_raw.csv
│   └── clean/                     # *_clean.csv
└── README.md
```

---

## 🗂️ Datasets

| Table | Raw rows | Clean rows |
|---|---|---|
| `athletes` | 186 | 180 (6 duplicates removed) |
| `wellness_checkins` | 25,385 | 25,385 |
| `training_load` | 26,655 sessions | 32,760 athlete-days (full daily calendar incl. rest days) |
| `injury_log` | 70 | 70 |

See `05_data_dictionary.md` for the meaning of every column.

---

## 🧹 Data Cleaning (Python)

Issues injected into the raw data and resolved in `02_clean_and_transform.py`:

- Duplicate athlete records removed
- Inconsistent text casing and whitespace standardised (`sport`, `injury_type`)
- Mixed date formats parsed with explicit per-format logic
- Sleep recorded in minutes instead of hours corrected (2,589 rows)
- Implausible resting heart rate values (e.g. 12, 220, -5, 999 bpm) set to null
- Missing wellness scores imputed with per-athlete medians
- Every step written to `cleaning_audit_log.txt`

### 🐞 Bug found and fixed
Early versions mixed `DD/MM/YYYY` and `MM/DD/YYYY` date strings, which are mutually ambiguous. Pandas' `format="mixed"` parser also swapped day and month on some ISO dates when `dayfirst=True`. This silently pushed dates outside the monitoring window and distorted ACWR. **Fix:** the generator now uses only unambiguous formats, and the cleaner parses each known format explicitly.

---

## 📈 Key Metric: ACWR

**Acute:Chronic Workload Ratio** = 7-day rolling average load ÷ 28-day rolling average load, where daily load = session RPE × duration (minutes). Based on a widely used sports-science method (Gabbett, 2016).

| ACWR | Category |
|---|---|
| < 0.8 | Undertraining |
| 0.8 – 1.3 | Optimal ("sweet spot") |
| 1.3 – 1.5 | Elevated injury risk |
| > 1.5 | High injury risk |

**Resulting distribution:** Optimal 28,883 · Undertraining 2,344 · Insufficient Data 1,080 (28-day warm-up) · Elevated 439 · High Risk 14

---

## 🔍 SQL Analysis

`03_sql_analysis.sql` contains 18 queries using CTEs, window functions (`ROW_NUMBER`, `RANK`, `LAG`) and multi-table joins, including:

- Athletes currently in the High Risk ACWR zone
- Sustained risk streaks (3+ consecutive elevated/high days)
- Injury rate per 10 athletes by sport
- ACWR and wellness trends in the days before injury events
- Squad tier workload comparison
- Rising resting heart rate week-over-week (early overtraining signal)
- Wellness check-in compliance

> **Caveat:** injuries in this synthetic dataset are assigned randomly and are not driven by training load. The pre-injury queries demonstrate the method, not a real causal finding. On real platform data they would test the ACWR–injury relationship.

---

## 📊 Power BI Dashboard

`04_powerbi_dashboard_guide.md` specifies a 4-page dashboard:

1. **Institute Overview** – roster, injury trend, risk distribution
2. **Injury Risk Monitor** – watchlist, sustained streaks, ACWR trend with reference bands
3. **Wellness & Load Trends** – sleep/soreness/fatigue trends, squad comparison, resting HR flags
4. **Athlete Drill-Through** – single-athlete load, wellness and injury history

Includes star-schema model, DAX measures and layout notes.

---

## 🛠️ How to Run

```bash
pip install pandas numpy
python 01_generate_raw_data.py      # creates the 4 raw CSVs
python 02_clean_and_transform.py    # creates clean CSVs + audit log
```

Then load the clean CSVs into MySQL to run `03_sql_analysis.sql`, or into Power BI to follow the dashboard guide.

---

## 💡 Skills Demonstrated

- **Python:** synthetic data generation, ETL, rolling-window calculations, audit logging
- **SQL:** CTEs, window functions, joins, conditional aggregation
- **Power BI / DAX:** star schema, measures, drill-through
- **Domain knowledge:** applying a recognised sports-science workload metric

---

## 👤 Author

**Shital Isankar** · [LinkedIn](https://linkedin.com/in/shital-8a098839b/) · [GitHub](https://github.com/ShitalMIsankar)
