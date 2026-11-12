#!/usr/bin/env bash

# ==================================================
# Errors in the Drupal log (dblog) before and after a change
# (--update, --upgrade, --php)
#
# Old errors must not be put down to the change, and errors that repeat
# (a cron job, a search index) get new ids all the time. So errors are
# compared by kind: the type and the message without numbers, ids and
# HTML. After the change only kinds that were not in the log before
# count as new.
# ==================================================

# The highest id of an error before the change; empty when the log
# cannot be read (no dblog).
LOG_ERRORS_BEFORE_MAX=""
# The kinds of errors before the change: "count<TAB>kind<TAB>example".
LOG_ERRORS_BEFORE_KINDS=""

# The last 200 errors of the log as "id<TAB>kind<TAB>example" lines.
# $1: PHP version; $2: the function that runs Drush (run_project_drush
# or run_drush_with_php). Returns 1 when the log cannot be read.
read_log_errors() {
    local php_version="$1"
    local runner="${2:-run_project_drush}"
    local json

    json="$("$runner" "$RECORD_PROJECT_PATH" "$php_version" \
        watchdog:show --severity=Error --count=200 --format=json 2>/dev/null)" || return 1
    [[ -n "$json" ]] || return 1

    # Single quotes: PHP code, not shell code.
    # shellcheck disable=SC2016
    printf '%s' "$json" | "php${php_version}" -r '
$d = json_decode(stream_get_contents(STDIN), true);
if (!is_array($d)) { exit(1); }
foreach ($d as $k => $row) {
    if (!is_array($row)) { continue; }
    $type = trim(strip_tags((string) ($row["type"] ?? "")));
    $text = html_entity_decode(strip_tags((string) ($row["message"] ?? "")), ENT_QUOTES);
    $text = trim(preg_replace("/\s+/", " ", $text));
    $kind = preg_replace(["/0x[0-9a-f]+/i", "/[0-9]+/"], ["#", "#"], "$type: $text");
    echo (int) ($row["wid"] ?? $k), "\t", mb_substr($kind, 0, 200), "\t", mb_substr("$type: $text", 0, 160), "\n";
}
' 2>/dev/null
}

# Before the change: the highest id and the kinds of errors.
remember_log_errors() {
    local rows

    LOG_ERRORS_BEFORE_MAX=""
    LOG_ERRORS_BEFORE_KINDS=""
    rows="$(read_log_errors "$@")" || return 0

    LOG_ERRORS_BEFORE_MAX="$(awk -F'\t' 'BEGIN { m = 0 } $1 > m { m = $1 } END { print m }' <<< "$rows")"
    [[ -n "$rows" ]] || return 0

    LOG_ERRORS_BEFORE_KINDS="$(awk -F'\t' '
        { n[$2]++; if (!($2 in ex)) { ex[$2] = $3 } }
        END { for (k in n) { print n[k] "\t" k "\t" ex[k] } }' <<< "$rows" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2)"
}

# In the plan: kinds of errors that the log has many times already, so
# that they are known before and not taken for the change's afterwards.
print_repeating_log_errors() {
    local repeating

    repeating="$(awk -F'\t' '$1 >= 3' <<< "$LOG_ERRORS_BEFORE_KINDS")"
    [[ -n "$repeating" ]] || return 0

    echo "Log:          errors that repeat already (last 200 errors); afterwards they are"
    echo "              not counted as new:"
    head -n 5 <<< "$repeating" | awk -F'\t' '{ print "                - " $3 " (x" $1 ")" }'
}

# After the change: errors with a higher id, by kind. A kind that was in
# the log before is counted, not warned about. $1: PHP version; $2: the
# Drush runner; $3: when, e.g. "during the update". Returns 1 when there
# are new kinds of errors.
report_new_log_errors() {
    local php_version="$1"
    local runner="$2"
    local when="$3"
    local rows
    local after
    local new_kinds
    local repeated

    [[ -n "$LOG_ERRORS_BEFORE_MAX" ]] || return 0
    rows="$(read_log_errors "$php_version" "$runner")" || return 0
    after="$(awk -F'\t' -v max="$LOG_ERRORS_BEFORE_MAX" '$1 > max' <<< "$rows")"

    if [[ -z "$after" ]]; then
        echo "[OK] No new errors in the Drupal log (older ones are not counted)"
        return 0
    fi

    # Kinds not seen before: "count<TAB>example", most frequent first.
    new_kinds="$(awk -F'\t' '
        FNR == NR { old[$2] = 1; next }
        !($2 in old) { n[$2]++; if (!($2 in ex)) { ex[$2] = $3 } }
        END { for (k in n) { print n[k] "\t" ex[k] } }' \
        <(printf '%s\n' "$LOG_ERRORS_BEFORE_KINDS" | awk -F'\t' 'NF >= 2 { print "0\t" $2 }') - <<< "$after" |
        LC_ALL=C sort -t $'\t' -k1,1nr -k2,2)"
    repeated="$(awk -F'\t' '
        FNR == NR { old[$2] = 1; next }
        ($2 in old) { c++ }
        END { print c + 0 }' \
        <(printf '%s\n' "$LOG_ERRORS_BEFORE_KINDS" | awk -F'\t' 'NF >= 2 { print "0\t" $2 }') - <<< "$after")"

    if [[ -z "$new_kinds" ]]; then
        echo "[OK] No new kinds of errors in the Drupal log: $repeated more of the kinds that"
        echo "     were there before this run (not caused by it)"
        return 0
    fi

    echo "[WARNING] Drupal logged new kinds of errors $when:"
    head -n 5 <<< "$new_kinds" | awk -F'\t' '{ print "            - " $2 ($1 > 1 ? " (x" $1 ")" : "") }'

    if [[ "$repeated" -gt 0 ]]; then
        echo "          (and $repeated of the kinds that were there before; not counted)"
    fi

    echo "          Details: $(get_project_drush_hint "$php_version") watchdog:show --severity=Error"
    return 1
}
