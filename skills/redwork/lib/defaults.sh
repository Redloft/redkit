#!/usr/bin/env bash
# defaults.sh — единая секция числовых дефолтов redwork autonomy (spec v2 §Constants/defaults).
# Все [IMPL-DEFAULT], env-override. Источник правды для autonomy-gate.sh + (Phase C) watch/supervisor.
# Зачем единая секция: иначе autonomy-gate не тестируется герметично (5-way convergence панели #1).

REDWORK_WATCH_MINUTES_MIN="${REDWORK_WATCH_MINUTES_MIN:-5}"            # A5: require.watch_minutes >= этого
REDWORK_HEARTBEAT_INTERVAL_SEC="${REDWORK_HEARTBEAT_INTERVAL_SEC:-30}" # watch пишет liveness не реже
REDWORK_HEARTBEAT_STALE_SEC="${REDWORK_HEARTBEAT_STALE_SEC:-90}"       # супервизор: heartbeat старше → watcher мёртв
REDWORK_HEALTH_POLL_SEC="${REDWORK_HEALTH_POLL_SEC:-15}"               # C3/D2 health-poll интервал
REDWORK_SIGNAL_POLL_SEC="${REDWORK_SIGNAL_POLL_SEC:-15}"               # D2 signals-poll интервал
REDWORK_AUTONOMY_SUPERVISORS="systemd launchd cron"                    # допустимые durable-супервизоры (A5)
REDWORK_RESTORE_POINT_ID_FMT="rp-%Y%m%dT%H%M%SZ"                       # C2 restore-point id format
