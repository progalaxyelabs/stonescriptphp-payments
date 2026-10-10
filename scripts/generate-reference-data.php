<?php
declare(strict_types=1);

/**
 * Generates src/Core/Schema/functions/050_50_pay_ensure_reference_data.pgsql
 * from the reference-data seeder files, so the seeders remain the single
 * source of truth.
 *
 *   php scripts/generate-reference-data.php           # rewrite the file
 *   php scripts/generate-reference-data.php --check   # exit 1 if it is stale
 *
 * The seeders themselves stay plain "INSERT ... VALUES" statements because the
 * StoneScriptDB Gateway parses exactly that shape when it seeds a new database
 * and when it verifies a migrated one. This script only derives the
 * idempotent twin of them.
 */

$root = dirname(__DIR__);
$out  = $root . '/src/Core/Schema/functions/050_50_pay_ensure_reference_data.pgsql';

// Dependency order (parents before children). For tables whose natural key is
// not covered by a plain unique constraint, 'key' lists the columns that mean
// "this seed row already exists", compared NULL-safely and regardless of any
// local is_active / priority edits.
$seeders = [
    ['src/Invoicing/Schema/seeders/034_30_inv_gateways.pgsql'],
    ['src/Invoicing/Schema/seeders/034_31_inv_gateway_routing_rules.pgsql', 'key' => ['match_country_code', 'gateway_code']],
    ['src/Invoicing/Schema/seeders/034_32_inv_invoice_statuses.pgsql'],
    ['src/Invoicing/Schema/seeders/034_33_inv_invoice_status_transitions.pgsql'],
    ['src/Outbox/Schema/seeders/037_31_inv_outbox_directions.pgsql'],
    ['src/Outbox/Schema/seeders/037_30_inv_outbox_statuses.pgsql'],
    ['src/Outbox/Schema/seeders/037_32_inv_outbox_intimation_statuses.pgsql'],
    ['src/Outbox/Schema/seeders/037_33_inv_outbox_config.pgsql'],
    ['src/Tax/India/Schema/seeders/025_31_inv_gst_state_codes.pgsql'],
    ['src/Tax/India/Schema/seeders/025_32_inv_gst_state_name_aliases.pgsql'],
    ['src/Tax/India/Schema/seeders/026_31_inv_gst_config.pgsql'],
    ['src/Tax/India/Schema/seeders/026_32_inv_gst_rate_slabs.pgsql'],
    ['src/Tax/India/Schema/seeders/032_31_inv_fx_reference_rates.pgsql'],
    ['src/Tax/Schema/seeders/033_02_inv_tax_scheme_seed.pgsql'],
    ['src/Core/Schema/seeders/051_31_pay_config.pgsql'],
];

/** Quote-aware scan: returns [statementText, endOffset] of the first INSERT. */
function extractInsert(string $sql): string
{
    if (!preg_match('/INSERT\s+INTO\s+/i', $sql, $m, PREG_OFFSET_CAPTURE)) {
        throw new RuntimeException('no INSERT found');
    }
    $start = $m[0][1];
    $len = strlen($sql);
    $inStr = false;
    $paren = 0;
    for ($i = $start; $i < $len; $i++) {
        $c = $sql[$i];
        if ($inStr) {
            if ($c === "'") {
                if (($sql[$i + 1] ?? '') === "'") { $i++; continue; }
                $inStr = false;
            }
            continue;
        }
        if ($c === "'") { $inStr = true; continue; }
        if ($c === '-' && ($sql[$i + 1] ?? '') === '-') {      // line comment
            $nl = strpos($sql, "\n", $i);
            $i = $nl === false ? $len : $nl;
            continue;
        }
        if ($c === '(') { $paren++; }
        if ($c === ')') { $paren--; }
        if ($c === ';' && $paren === 0) {
            return substr($sql, $start, $i - $start);
        }
    }
    throw new RuntimeException('unterminated INSERT');
}

/** Splits "(a,b),(c,d)" into raw tuple bodies, quote- and paren-aware. */
function splitTuples(string $values): array
{
    $tuples = [];
    $len = strlen($values);
    $inStr = false; $depth = 0; $buf = '';
    for ($i = 0; $i < $len; $i++) {
        $c = $values[$i];
        if ($inStr) {
            $buf .= $c;
            if ($c === "'") {
                if (($values[$i + 1] ?? '') === "'") { $buf .= "'"; $i++; continue; }
                $inStr = false;
            }
            continue;
        }
        if ($c === '-' && ($values[$i + 1] ?? '') === '-') {
            $nl = strpos($values, "\n", $i);
            $i = $nl === false ? $len : $nl;
            continue;
        }
        if ($c === "'") { $inStr = true; $buf .= $c; continue; }
        if ($c === '(') { if ($depth++ === 0) { $buf = ''; continue; } }
        if ($c === ')') { if (--$depth === 0) { $tuples[] = trim($buf); $buf = ''; continue; } }
        if ($depth > 0) { $buf .= $c; }
    }
    return $tuples;
}

/** Splits a tuple body into top-level comma separated value expressions. */
function splitValues(string $tuple): array
{
    $vals = []; $buf = ''; $inStr = false; $depth = 0;
    $len = strlen($tuple);
    for ($i = 0; $i < $len; $i++) {
        $c = $tuple[$i];
        if ($inStr) {
            $buf .= $c;
            if ($c === "'") {
                if (($tuple[$i + 1] ?? '') === "'") { $buf .= "'"; $i++; continue; }
                $inStr = false;
            }
            continue;
        }
        if ($c === "'") { $inStr = true; $buf .= $c; continue; }
        if ($c === '(') { $depth++; }
        if ($c === ')') { $depth--; }
        if ($c === ',' && $depth === 0) { $vals[] = trim($buf); $buf = ''; continue; }
        $buf .= $c;
    }
    $vals[] = trim($buf);
    return $vals;
}

$body = '';
foreach ($seeders as $spec) {
    $path = $root . '/' . $spec[0];
    $sql = (string) file_get_contents($path);
    $stmt = extractInsert($sql);
    if (!preg_match('/^INSERT\s+INTO\s+(\w+)\s*\(([^)]*)\)\s*VALUES\s*(.*)$/is', $stmt, $m)) {
        throw new RuntimeException("cannot parse $path");
    }
    [$table, $cols, $values] = [$m[1], array_map('trim', explode(',', $m[2])), $m[3]];
    // a seeder may already carry its own conflict clause; we always add ours
    $values = preg_replace('/\s+ON\s+CONFLICT\b.*$/is', '', $values);

    $body .= "    -- {$table}  (from " . basename($path) . ")\n";
    if (isset($spec['key'])) {
        foreach (splitTuples($values) as $tuple) {
            $vals = splitValues($tuple);
            if (count($vals) !== count($cols)) {
                throw new RuntimeException("column/value mismatch in $path");
            }
            $byCol = array_combine($cols, $vals);
            $match = [];
            foreach ($spec['key'] as $k) {
                $match[] = "x.{$k} IS NOT DISTINCT FROM {$byCol[$k]}";
            }
            $body .= "    INSERT INTO {$table} (" . implode(', ', $cols) . ")\n"
                . '    SELECT ' . implode(', ', $vals) . "\n"
                . "    WHERE NOT EXISTS (SELECT 1 FROM {$table} x WHERE " . implode(' AND ', $match) . ")\n"
                . "    ON CONFLICT DO NOTHING;\n"
                . "    GET DIAGNOSTICS v_n = ROW_COUNT;\n"
                . "    v_total := v_total + v_n;\n";
        }
        $body .= "    table_name := '{$table}'; rows_inserted := v_total; RETURN NEXT; v_total := 0;\n\n";
    } else {
        $body .= "    INSERT INTO {$table} (" . implode(', ', $cols) . ") VALUES\n"
            . '    ' . trim($values) . "\n"
            . "    ON CONFLICT DO NOTHING;\n"
            . "    GET DIAGNOSTICS v_n = ROW_COUNT;\n"
            . "    table_name := '{$table}'; rows_inserted := v_n; RETURN NEXT;\n\n";
    }
}

$header = <<<'SQL'
-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_ensure_reference_data
--
-- GENERATED FILE - do not edit by hand.
--   regenerate: php scripts/generate-reference-data.php
--   freshness : php scripts/generate-reference-data.php --check   (also a test)
-- Source of truth: the reference-data seeders under src/**/Schema/seeders/.
--
-- WHY THIS EXISTS
-- The StoneScriptDB Gateway seeds reference data only when it CREATES a
-- database. A migrate of an existing database merely VERIFIES the seeder rows
-- and refuses ("MISSING SEEDER RECORDS") when any are absent, so a database
-- that was created before this package was staged, or that was only partly
-- seeded earlier, can never reach a verified state on its own.
--
-- WHAT IT DOES
-- Inserts every reference row that is missing, in foreign-key order, and
-- nothing else:
--   * Existing rows are never updated or deleted, so a local edit (for example
--     a deployment's own gateway checkout endpoint) is preserved.
--   * Routing rules are matched on (country, gateway), not on priority or
--     is_active, so a locally re-prioritised or disabled rule is not
--     re-created as a duplicate.
--   * Running it again changes nothing.
-- Returns one row per table with the number of rows it inserted (all zero on a
-- healthy database; a non-zero count tells an operator rows were missing).
--
-- HOW A CONSUMER USES IT
-- Add one migration file to the platform's own migrations (the gateway runs
-- migrations after tables and functions are deployed and before it verifies
-- the seeders):
--
--     SELECT * FROM _pay_ensure_reference_data();
--
-- A release of this package that adds reference rows needs a new such
-- migration in the consuming platform, because the gateway applies a
-- migration file once.
--
-- INTERNAL (leading underscore): not an application entry point. It is run by a platform migration or by an operator in
-- psql, never by request code; the StoneScriptDB Gateway refuses to /call names that start with an underscore.
-- Not a hot-path function.
SQL;

$sql = $header . "\n"
    . "CREATE OR REPLACE FUNCTION _pay_ensure_reference_data()\n"
    . "RETURNS TABLE (table_name TEXT, rows_inserted BIGINT)\n"
    . "LANGUAGE plpgsql\n"
    . "AS \$\$\n"
    . "DECLARE\n"
    . "    v_n     BIGINT;\n"
    . "    v_total BIGINT := 0;\n"
    . "BEGIN\n"
    . $body
    . "    RETURN;\n"
    . "END;\n"
    . "\$\$;\n";

if (in_array('--check', $argv, true)) {
    $current = is_file($out) ? (string) file_get_contents($out) : '';
    if ($current !== $sql) {
        fwrite(STDERR, "STALE: {$out} differs from what the seeders generate. Run scripts/generate-reference-data.php\n");
        exit(1);
    }
    echo "fresh\n";
    exit(0);
}
file_put_contents($out, $sql);
echo "wrote {$out}\n";
