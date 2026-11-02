-- ============================================================================
-- ATHLETE PERFORMANCE & WELLNESS MONITORING - SQL ANALYSIS
-- ============================================================================
-- Dialect: MySQL 8+ (CTEs, window functions). Tested logic against SQLite;
-- adjust date functions (STR_TO_DATE / DATE_FORMAT) if porting to another RDBMS.
--
-- Tables:
--   athletes(athlete_id, full_name, sport, squad_tier, age, gender,
--            onboarding_date, status)
--   wellness_checkins(athlete_id, checkin_date, sleep_hours, soreness_1_10,
--                      fatigue_1_10, mood_1_10, resting_hr)
--   training_load(athlete_id, session_date, daily_load, acute_7d,
--                  chronic_28d, acwr, risk_flag)
--   injury_log(athlete_id, injury_type, onset_date, days_missed, return_status)
-- ============================================================================


-- 1. Roster overview: active athlete count by sport and squad tier
SELECT
    sport,
    squad_tier,
    COUNT(*) AS athlete_count
FROM athletes
WHERE status = 'Active'
GROUP BY sport, squad_tier
ORDER BY sport, squad_tier;


-- 2. Wellness check-in compliance rate per athlete (last 90 days)
SELECT
    a.athlete_id,
    a.sport,
    COUNT(w.checkin_date) AS checkins_logged,
    90 AS days_in_window,
    ROUND(COUNT(w.checkin_date) * 100.0 / 90, 1) AS compliance_pct
FROM athletes a
LEFT JOIN wellness_checkins w
    ON a.athlete_id = w.athlete_id
    AND w.checkin_date >= DATE_SUB(CURDATE(), INTERVAL 90 DAY)
GROUP BY a.athlete_id, a.sport
ORDER BY compliance_pct ASC;


-- 3. Athletes currently in "High Risk" ACWR zone (most recent recorded date per athlete)
WITH latest_load AS (
    SELECT
        athlete_id,
        session_date,
        acwr,
        risk_flag,
        ROW_NUMBER() OVER (PARTITION BY athlete_id ORDER BY session_date DESC) AS rn
    FROM training_load
)
SELECT
    l.athlete_id,
    a.sport,
    a.squad_tier,
    l.session_date,
    l.acwr,
    l.risk_flag
FROM latest_load l
JOIN athletes a ON a.athlete_id = l.athlete_id
WHERE l.rn = 1 AND l.risk_flag = 'High Risk'
ORDER BY l.acwr DESC;


-- 4. Athletes with SUSTAINED elevated risk: 3+ consecutive days of Elevated/High Risk
WITH flagged AS (
    SELECT
        athlete_id,
        session_date,
        risk_flag,
        CASE WHEN risk_flag IN ('Elevated Risk', 'High Risk') THEN 1 ELSE 0 END AS is_risky
    FROM training_load
),
grp AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY athlete_id ORDER BY session_date)
        - ROW_NUMBER() OVER (PARTITION BY athlete_id, is_risky ORDER BY session_date) AS streak_group
    FROM flagged
)
SELECT
    athlete_id,
    MIN(session_date) AS streak_start,
    MAX(session_date) AS streak_end,
    COUNT(*) AS consecutive_days
FROM grp
WHERE is_risky = 1
GROUP BY athlete_id, streak_group
HAVING COUNT(*) >= 3
ORDER BY consecutive_days DESC;


-- 5. Injury rate by sport (injuries per 10 athletes)
SELECT
    a.sport,
    COUNT(DISTINCT a.athlete_id) AS roster_size,
    COUNT(i.athlete_id) AS injury_events,
    ROUND(COUNT(i.athlete_id) * 10.0 / COUNT(DISTINCT a.athlete_id), 2) AS injuries_per_10_athletes
FROM athletes a
LEFT JOIN injury_log i ON a.athlete_id = i.athlete_id
GROUP BY a.sport
ORDER BY injuries_per_10_athletes DESC;


-- 6. Average days missed by injury type, ranked
SELECT
    injury_type,
    COUNT(*) AS event_count,
    ROUND(AVG(days_missed), 1) AS avg_days_missed,
    MAX(days_missed) AS max_days_missed
FROM injury_log
GROUP BY injury_type
ORDER BY avg_days_missed DESC;


-- 7. ACWR in the 14 days BEFORE injury onset (validates the "spike = risk" hypothesis)
WITH pre_injury_window AS (
    SELECT
        i.athlete_id,
        i.injury_type,
        i.onset_date,
        t.session_date,
        t.acwr
    FROM injury_log i
    JOIN training_load t
        ON t.athlete_id = i.athlete_id
        AND t.session_date BETWEEN DATE_SUB(i.onset_date, INTERVAL 14 DAY) AND i.onset_date
)
SELECT
    athlete_id,
    injury_type,
    onset_date,
    ROUND(AVG(acwr), 2) AS avg_acwr_14d_pre_injury,
    ROUND(MAX(acwr), 2) AS peak_acwr_14d_pre_injury
FROM pre_injury_window
GROUP BY athlete_id, injury_type, onset_date
ORDER BY avg_acwr_14d_pre_injury DESC;


-- 8. Wellness decline before injury: avg soreness/fatigue in the 7 days pre-injury
--    vs each athlete's overall baseline
WITH baseline AS (
    SELECT athlete_id, AVG(soreness_1_10) AS base_soreness, AVG(fatigue_1_10) AS base_fatigue
    FROM wellness_checkins
    GROUP BY athlete_id
),
pre_injury AS (
    SELECT
        i.athlete_id,
        i.onset_date,
        AVG(w.soreness_1_10) AS pre_soreness,
        AVG(w.fatigue_1_10) AS pre_fatigue
    FROM injury_log i
    JOIN wellness_checkins w
        ON w.athlete_id = i.athlete_id
        AND w.checkin_date BETWEEN DATE_SUB(i.onset_date, INTERVAL 7 DAY) AND i.onset_date
    GROUP BY i.athlete_id, i.onset_date
)
SELECT
    p.athlete_id,
    p.onset_date,
    ROUND(p.pre_soreness, 1) AS soreness_7d_pre_injury,
    ROUND(b.base_soreness, 1) AS baseline_soreness,
    ROUND(p.pre_soreness - b.base_soreness, 1) AS soreness_delta,
    ROUND(p.pre_fatigue, 1) AS fatigue_7d_pre_injury,
    ROUND(b.base_fatigue, 1) AS baseline_fatigue
FROM pre_injury p
JOIN baseline b ON b.athlete_id = p.athlete_id
ORDER BY soreness_delta DESC;


-- 9. Squad tier training load comparison (Podium vs Development vs Talent ID)
SELECT
    a.squad_tier,
    ROUND(AVG(t.daily_load), 1) AS avg_daily_load,
    ROUND(AVG(t.acwr), 2) AS avg_acwr,
    SUM(CASE WHEN t.risk_flag = 'High Risk' THEN 1 ELSE 0 END) AS high_risk_days
FROM training_load t
JOIN athletes a ON a.athlete_id = t.athlete_id
GROUP BY a.squad_tier
ORDER BY avg_daily_load DESC;


-- 10. Top 15 athletes by cumulative training load (monitoring workload leaders)
SELECT
    a.athlete_id,
    a.sport,
    a.squad_tier,
    ROUND(SUM(t.daily_load), 0) AS total_load,
    ROUND(AVG(t.daily_load), 1) AS avg_daily_load
FROM training_load t
JOIN athletes a ON a.athlete_id = t.athlete_id
GROUP BY a.athlete_id, a.sport, a.squad_tier
ORDER BY total_load DESC
LIMIT 15;


-- 11. Rank athletes WITHIN their sport by average session intensity (window function)
WITH sport_avg AS (
    SELECT
        athlete_id,
        AVG(daily_load) AS avg_load
    FROM training_load
    WHERE daily_load > 0
    GROUP BY athlete_id
)
SELECT
    a.sport,
    s.athlete_id,
    ROUND(s.avg_load, 1) AS avg_load,
    RANK() OVER (PARTITION BY a.sport ORDER BY s.avg_load DESC) AS load_rank_in_sport
FROM sport_avg s
JOIN athletes a ON a.athlete_id = s.athlete_id
ORDER BY a.sport, load_rank_in_sport;


-- 12. Resting heart rate trend flag: athletes with rising RHR (possible overtraining/
--     illness signal) using LAG to compare week-over-week average
WITH weekly_rhr AS (
    SELECT
        athlete_id,
        YEARWEEK(checkin_date) AS yr_wk,
        AVG(resting_hr) AS avg_rhr
    FROM wellness_checkins
    WHERE resting_hr IS NOT NULL
    GROUP BY athlete_id, YEARWEEK(checkin_date)
),
with_prev AS (
    SELECT
        *,
        LAG(avg_rhr) OVER (PARTITION BY athlete_id ORDER BY yr_wk) AS prev_week_rhr
    FROM weekly_rhr
)
SELECT
    athlete_id,
    yr_wk,
    ROUND(avg_rhr, 1) AS avg_rhr,
    ROUND(prev_week_rhr, 1) AS prev_week_rhr,
    ROUND(avg_rhr - prev_week_rhr, 1) AS rhr_change
FROM with_prev
WHERE prev_week_rhr IS NOT NULL
  AND avg_rhr - prev_week_rhr >= 4   -- flag jumps of 4+ bpm week over week
ORDER BY rhr_change DESC;


-- 13. Monthly injury count trend (for a Power BI line chart)
SELECT
    DATE_FORMAT(onset_date, '%Y-%m') AS injury_month,
    COUNT(*) AS injury_count,
    ROUND(AVG(days_missed), 1) AS avg_days_missed
FROM injury_log
GROUP BY DATE_FORMAT(onset_date, '%Y-%m')
ORDER BY injury_month;


-- 14. Return-to-play status breakdown
SELECT
    return_status,
    COUNT(*) AS athlete_count,
    ROUND(AVG(days_missed), 1) AS avg_days_missed
FROM injury_log
GROUP BY return_status;


-- 15. Athletes onboarded 6+ months ago with low recent compliance (retention/engagement risk)
SELECT
    a.athlete_id,
    a.sport,
    a.onboarding_date,
    COUNT(w.checkin_date) AS checkins_last_30d
FROM athletes a
LEFT JOIN wellness_checkins w
    ON a.athlete_id = w.athlete_id
    AND w.checkin_date >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
WHERE a.onboarding_date <= DATE_SUB(CURDATE(), INTERVAL 180 DAY)
GROUP BY a.athlete_id, a.sport, a.onboarding_date
HAVING checkins_last_30d < 10
ORDER BY checkins_last_30d ASC;


-- 16. Risk flag distribution by sport (CTE + conditional aggregation)
WITH risk_summary AS (
    SELECT
        a.sport,
        t.risk_flag,
        COUNT(*) AS days_count
    FROM training_load t
    JOIN athletes a ON a.athlete_id = t.athlete_id
    GROUP BY a.sport, t.risk_flag
)
SELECT
    sport,
    SUM(CASE WHEN risk_flag = 'Undertraining' THEN days_count ELSE 0 END) AS undertraining_days,
    SUM(CASE WHEN risk_flag = 'Optimal' THEN days_count ELSE 0 END) AS optimal_days,
    SUM(CASE WHEN risk_flag = 'Elevated Risk' THEN days_count ELSE 0 END) AS elevated_risk_days,
    SUM(CASE WHEN risk_flag = 'High Risk' THEN days_count ELSE 0 END) AS high_risk_days
FROM risk_summary
GROUP BY sport
ORDER BY high_risk_days DESC;


-- 17. Average sleep, soreness, fatigue, mood by squad tier (wellness snapshot)
SELECT
    a.squad_tier,
    ROUND(AVG(w.sleep_hours), 2) AS avg_sleep_hours,
    ROUND(AVG(w.soreness_1_10), 2) AS avg_soreness,
    ROUND(AVG(w.fatigue_1_10), 2) AS avg_fatigue,
    ROUND(AVG(w.mood_1_10), 2) AS avg_mood
FROM wellness_checkins w
JOIN athletes a ON a.athlete_id = w.athlete_id
GROUP BY a.squad_tier;


-- 18. Injury-prone athletes: 2+ injury events (repeat injury watch list)
SELECT
    i.athlete_id,
    a.sport,
    COUNT(*) AS injury_events,
    SUM(i.days_missed) AS total_days_missed
FROM injury_log i
JOIN athletes a ON a.athlete_id = i.athlete_id
GROUP BY i.athlete_id, a.sport
HAVING COUNT(*) >= 2
ORDER BY total_days_missed DESC;
