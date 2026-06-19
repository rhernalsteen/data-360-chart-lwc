/**
 * Apex controller for the dataCloudChart LWC.
 *
 * Runs `without sharing` so DMO/DLO aggregate queries succeed in system mode.
 *
 * Read-only — no DML, no callouts.
 */
public without sharing class DataCloudChartController {

    private static final Pattern API_NAME_PATTERN = Pattern.compile(
        '(?i)^[A-Za-z][A-Za-z0-9_]*(__(c|dlm|dll|dlo|e|b|mdt|share|history))?$'
    );
    private static final Set<String> VALID_DIRECTIONS      = new Set<String>{ 'ASC', 'DESC' };
    private static final Set<String> VALID_AGGREGATES      = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };
    private static final Set<String> ALLOWED_OPERATORS     = new Set<String>{
        'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'in', 'notnull', 'isnull'
    };
    private static final Set<String> VALID_DATE_TRUNCATIONS = new Set<String>{ 'day', 'week', 'month', 'quarter', 'year' };
    private static final Integer MAX_GROUPS     = 100;  // hard cap
    private static final Integer DEFAULT_GROUPS = 25;   // default limit

    // Filter condition sent from the LWC after client-side DSL parsing and
    // placeholder resolution. Each field and operator are server-validated;
    // values are escaped before being interpolated into the SOQL string.
    public class FilterCondition {
        @AuraEnabled public String field;
        @AuraEnabled public String operator;
        @AuraEnabled public String value;
    }

    public class QueryParams {
        @AuraEnabled public String              targetObject;
        @AuraEnabled public String              targetField;
        @AuraEnabled public String              sourceValue;
        @AuraEnabled public String              groupByField;
        @AuraEnabled public String              aggregateFunction; // SUM, COUNT, AVG, MIN, MAX
        @AuraEnabled public String              aggregateField;    // blank OK when COUNT
        @AuraEnabled public String              sortBy;            // 'aggregate' | 'groupBy'
        @AuraEnabled public String              sortDirection;     // ASC | DESC
        @AuraEnabled public String              chartType;         // 'kpi' skips GROUP BY
        @AuraEnabled public String              groupByTrunc;      // day|week|month|quarter|year
        @AuraEnabled public String              stackByField;      // optional second GROUP BY for stacked bar
        @AuraEnabled public Integer             maxGroups;         // 1–100, default 25
        @AuraEnabled public List<FilterCondition> filters;
    }

    public class ChartResult {
        // Each row: { groupValue: String, aggValue: Decimal/Integer, _rowKey: String }
        @AuraEnabled public List<Map<String, Object>> rows;
        @AuraEnabled public String groupByFieldLabel;
        @AuraEnabled public String aggregateFieldLabel;
    }

    /**
     * Workaround: `throw new AuraHandledException(msg)` alone surfaces
     * "Script-thrown exception". setMessage() must be called explicitly.
     */
    @TestVisible
    private static void throwSafe(String msg) {
        AuraHandledException ahe = new AuraHandledException(msg);
        ahe.setMessage(msg);
        throw ahe;
    }

    @TestVisible
    private static void assertValidApiName(String name, String fieldDescription) {
        if (String.isBlank(name) || !API_NAME_PATTERN.matcher(name).matches()) {
            throwSafe('Invalid ' + fieldDescription + ': ' + name);
        }
    }

    /**
     * @AuraEnabled wrapper — returns a JSON String to bypass serialization issues
     * with Data Cloud DLM/DLO aggregate result types.
     */
    @AuraEnabled
    public static String fetchChartDataJson(String paramsJson) {
        try {
            ChartResult result = getChartData(paramsJson);
            return JSON.serialize(result);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throwSafe('[FETCH_WRAPPER][' + e.getTypeName() + '] ' + e.getMessage());
            return null;
        }
    }

    /**
     * Typed implementation — not @AuraEnabled. Callable from tests and the wrapper above.
     */
    public static ChartResult getChartData(String paramsJson) {
        String phase = 'INIT';
        String soqlForDiagnostic = '';
        try {
            phase = 'DESERIALIZE';
            if (String.isBlank(paramsJson)) {
                throwSafe('Configuration incomplete.');
            }
            QueryParams params;
            try {
                params = (QueryParams) JSON.deserialize(paramsJson, QueryParams.class);
            } catch (Exception jsonEx) {
                throwSafe('Configuration incomplete.');
            }
            if (params == null) {
                throwSafe('Configuration incomplete.');
            }

            phase = 'GUARD';
            if (String.isNotBlank(params.targetObject))      { params.targetObject      = params.targetObject.trim(); }
            if (String.isNotBlank(params.targetField))       { params.targetField       = params.targetField.trim(); }
            if (String.isNotBlank(params.groupByField))      { params.groupByField      = params.groupByField.trim(); }
            if (String.isNotBlank(params.aggregateField))    { params.aggregateField    = params.aggregateField.trim(); }
            if (String.isNotBlank(params.aggregateFunction)) {
                params.aggregateFunction = params.aggregateFunction.trim().toUpperCase();
            }
            if (String.isNotBlank(params.groupByTrunc)) { params.groupByTrunc = params.groupByTrunc.trim().toLowerCase(); }
            if (String.isNotBlank(params.stackByField)) { params.stackByField = params.stackByField.trim(); }
            if (String.isNotBlank(params.chartType))    { params.chartType    = params.chartType.trim().toLowerCase(); }
            Boolean isKpi = 'kpi'.equals(params.chartType);

            if (String.isBlank(params.targetObject) || String.isBlank(params.targetField)) {
                throwSafe('Target object and target field are required.');
            }
            if (!isKpi && String.isBlank(params.groupByField)) {
                throwSafe('Group By field is required.');
            }
            if (String.isBlank(params.aggregateFunction) || !VALID_AGGREGATES.contains(params.aggregateFunction)) {
                throwSafe('Aggregate function must be one of: SUM, COUNT, AVG, MIN, MAX.');
            }
            if (params.aggregateFunction != 'COUNT' && String.isBlank(params.aggregateField)) {
                throwSafe('Aggregate field is required for ' + params.aggregateFunction + '.');
            }
            if (String.isNotBlank(params.groupByTrunc) && !VALID_DATE_TRUNCATIONS.contains(params.groupByTrunc)) {
                throwSafe('Invalid Group By Truncation: ' + params.groupByTrunc + '. Must be one of: day, week, month, quarter, year.');
            }

            // Layer 1 — regex injection guard
            assertValidApiName(params.targetObject, 'target object');
            assertValidApiName(params.targetField, 'target field');
            if (!isKpi) { assertValidApiName(params.groupByField, 'group-by field'); }
            if (String.isNotBlank(params.aggregateField)) {
                assertValidApiName(params.aggregateField, 'aggregate field');
            }
            if (String.isNotBlank(params.stackByField)) { assertValidApiName(params.stackByField, 'stack-by field'); }
            if (params.filters != null) {
                for (FilterCondition fc : params.filters) {
                    if (fc == null) continue;
                    assertValidApiName(fc.field, 'filter field');
                    if (String.isBlank(fc.operator) || !ALLOWED_OPERATORS.contains(fc.operator)) {
                        throwSafe('Invalid filter operator: ' + fc.operator);
                    }
                }
            }

            phase = 'DESCRIBE';
            // Layer 2 — Schema describe (best-effort)
            Map<String, Schema.SObjectField> fieldMap = null;
            Schema.DisplayType groupByFieldType = null;
            String groupByFieldLabel   = null;
            String aggregateFieldLabel = null;
            try {
                List<Schema.DescribeSObjectResult> descs =
                    Schema.describeSObjects(new List<String>{ params.targetObject });
                if (descs != null && !descs.isEmpty() && descs[0] != null) {
                    fieldMap = descs[0].fields.getMap();
                }
            } catch (Exception describeEx) {
                System.debug(LoggingLevel.WARN,
                    'describeSObjects failed for ' + params.targetObject +
                    '; relying on regex pre-filter. ' + describeEx.getMessage());
            }

            phase = 'VALIDATE_FIELDS';
            if (fieldMap != null) {
                if (fieldMap.get(params.targetField.toLowerCase()) == null) {
                    throwSafe('Invalid target field: ' + params.targetField);
                }
                if (!isKpi && fieldMap != null) {
                    Schema.SObjectField groupSField = fieldMap.get(params.groupByField.toLowerCase());
                    if (groupSField == null) { throwSafe('Invalid group-by field: ' + params.groupByField); }
                    Schema.DescribeFieldResult groupDescribe = groupSField.getDescribe();
                    groupByFieldType  = groupDescribe.getType();
                    groupByFieldLabel = groupDescribe.getLabel();
                    // also validate stackByField if present
                    if (String.isNotBlank(params.stackByField) && fieldMap.get(params.stackByField.toLowerCase()) == null) {
                        throwSafe('Invalid stack-by field: ' + params.stackByField);
                    }
                }
                if (String.isNotBlank(params.aggregateField)) {
                    Schema.SObjectField aggSField = fieldMap.get(params.aggregateField.toLowerCase());
                    if (aggSField == null) { throwSafe('Invalid aggregate field: ' + params.aggregateField); }
                    aggregateFieldLabel = aggSField.getDescribe().getLabel();
                }
                if (params.filters != null) {
                    for (FilterCondition fc : params.filters) {
                        if (fc == null) continue;
                        if (fieldMap.get(fc.field.toLowerCase()) == null) {
                            throwSafe('Invalid filter field: ' + fc.field);
                        }
                    }
                }
            }

            phase = 'BUILD_SOQL';
            String rawDir = String.isNotBlank(params.sortDirection)
                ? params.sortDirection.toUpperCase()
                : 'DESC';
            String dir = VALID_DIRECTIONS.contains(rawDir) ? rawDir : 'DESC';

            // Clamp maxGroups: default 25, hard cap 100
            Integer maxGroups = DEFAULT_GROUPS;
            if (params.maxGroups != null && params.maxGroups > 0) {
                maxGroups = Math.min(params.maxGroups, MAX_GROUPS);
            }

            // Date bucketing path: Data Cloud SOQL cannot truncate dates — CALENDAR_MONTH /
            // CALENDAR_YEAR / DAY_ONLY etc. are unsupported on DMOs. Route grouped-by-date
            // queries through the Data Cloud Query API (ANSI SQL DATE_TRUNC) via ConnectApi,
            // which runs in-org with no Named Credential. All other queries stay on the
            // proven SOQL/AggregateResult path below.
            Boolean useAnsiDateBucket = !isKpi
                && String.isNotBlank(params.groupByTrunc)
                && VALID_DATE_TRUNCATIONS.contains(params.groupByTrunc);

            List<Map<String, Object>> rows = new List<Map<String, Object>>();

            if (useAnsiDateBucket) {
                String ansiSql = buildAnsiBucketSql(params, dir, maxGroups);
                soqlForDiagnostic = ansiSql;

                phase = 'EXECUTE_QUERY';
                ConnectApi.CdpQueryInput inp = new ConnectApi.CdpQueryInput();
                inp.sql = ansiSql;
                ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(inp);

                phase = 'CONVERT_RESULTS';
                // res.data is List<ConnectApi.CdpQueryV2Row> (not List<List>). Round-trip
                // through JSON to get plain positional rows: [bucket, aggval, (stackval)].
                Integer idx = 0;
                if (res != null && res.data != null) {
                    List<Object> dataRows = (List<Object>) JSON.deserializeUntyped(JSON.serialize(res.data));
                    for (Object rowObj : dataRows) {
                        List<Object> r = (List<Object>) rowObj;
                        Map<String, Object> row = new Map<String, Object>();
                        Object bucket = r.size() > 0 ? r.get(0) : null;
                        Object aggv   = r.size() > 1 ? r.get(1) : null;
                        // Data Cloud may return aggregates as high-precision strings; coerce to a
                        // number so the chart renders identically to the SOQL/AggregateResult path.
                        Decimal aggNum = 0;
                        if (aggv != null) {
                            try { aggNum = Decimal.valueOf(String.valueOf(aggv)); }
                            catch (Exception ignored) { aggNum = 0; }
                        }
                        row.put('groupValue', bucket != null ? String.valueOf(bucket) : '');
                        row.put('aggValue',   aggNum);
                        if (String.isNotBlank(params.stackByField)) {
                            Object sv = r.size() > 2 ? r.get(2) : null;
                            row.put('stackValue', sv != null ? String.valueOf(sv) : '');
                        }
                        row.put('_rowKey', String.valueOf(idx));
                        rows.add(row);
                        idx++;
                    }
                }
            } else {
                // ---------- SOQL / AggregateResult path (no date bucketing) ----------
                String groupByExpr   = isKpi ? null : buildGroupByExpression(params.groupByField, params.groupByTrunc, groupByFieldType);
                Boolean isFunctionExpr = groupByExpr != null && !groupByExpr.equalsIgnoreCase(params.groupByField);
                String groupReadKey    = isFunctionExpr ? 'groupBucket' : (isKpi ? null : params.groupByField);
                String selectGroupExpr = isFunctionExpr ? (groupByExpr + ' groupBucket') : (isKpi ? null : params.groupByField);

                // COUNT(Id) avoids "Grouped field should not be aggregated"; COUNT() is invalid in mixed SELECT.
                String aggFn = (params.aggregateFunction == 'COUNT')
                    ? 'COUNT(Id)'
                    : params.aggregateFunction + '(' + params.aggregateField + ')';

                String whereClause = params.targetField + ' = :sourceValue';
                if (params.filters != null && !params.filters.isEmpty()) {
                    for (FilterCondition fc : params.filters) {
                        if (fc == null) continue;
                        whereClause += ' AND ' + buildFilterClause(fc);
                    }
                }

                String query;
                if (isKpi) {
                    // Scalar aggregate — no GROUP BY/LIMIT (rejected on non-grouped aggregates).
                    query = 'SELECT ' + aggFn
                          + ' FROM '  + params.targetObject
                          + ' WHERE ' + whereClause;
                } else {
                    Boolean sortByGroup = 'groupBy'.equalsIgnoreCase(params.sortBy);
                    String orderByExpr  = sortByGroup ? groupByExpr : aggFn;

                    String selectPart  = selectGroupExpr + ', ' + aggFn;
                    String groupByPart = groupByExpr;
                    if (String.isNotBlank(params.stackByField)) {
                        selectPart  += ', ' + params.stackByField;
                        groupByPart += ', ' + params.stackByField;
                    }

                    query = 'SELECT ' + selectPart
                          + ' FROM '    + params.targetObject
                          + ' WHERE '   + whereClause
                          + ' GROUP BY ' + groupByPart
                          + ' ORDER BY ' + orderByExpr + ' ' + dir
                          + ' LIMIT :maxGroups';
                }

                String sourceValue = params.sourceValue;
                soqlForDiagnostic  = query;

                phase = 'EXECUTE_QUERY';
                List<AggregateResult> results = (List<AggregateResult>) Database.query(query);

                phase = 'CONVERT_RESULTS';
                Integer idx = 0;
                for (AggregateResult ar : results) {
                    Map<String, Object> row = new Map<String, Object>();
                    if (isKpi) {
                        row.put('groupValue', '');
                        row.put('aggValue',   ar.get('expr0') != null ? ar.get('expr0') : 0);
                    } else {
                        Object groupVal = ar.get(groupReadKey);
                        if (groupVal == null && isFunctionExpr) {
                            groupVal = ar.get(params.groupByField);
                        }
                        row.put('groupValue', groupVal != null ? String.valueOf(groupVal) : '');
                        row.put('aggValue',   ar.get('expr0') != null ? ar.get('expr0') : 0);
                        if (String.isNotBlank(params.stackByField)) {
                            Object stackVal = ar.get(params.stackByField);
                            row.put('stackValue', stackVal != null ? String.valueOf(stackVal) : '');
                        }
                    }
                    row.put('_rowKey', String.valueOf(idx));
                    rows.add(row);
                    idx++;
                }
            }

            ChartResult result = new ChartResult();
            result.rows               = rows;
            result.groupByFieldLabel   = groupByFieldLabel;
            result.aggregateFieldLabel = aggregateFieldLabel;
            return result;

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'getChartData failed in phase=' + phase + ': '
                + e.getTypeName() + ' — ' + e.getMessage()
                + (String.isNotBlank(soqlForDiagnostic) ? '\nSOQL: ' + soqlForDiagnostic : '')
                + '\n' + e.getStackTraceString());
            String diag = '[' + phase + '][' + e.getTypeName() + '] ' + e.getMessage();
            if (phase == 'EXECUTE_QUERY' || phase == 'CONVERT_RESULTS') {
                diag += ' | SOQL: ' + soqlForDiagnostic;
            }
            throwSafe(diag);
            return null;
        }
    }

    /**
     * Returns the appropriate SOQL GROUP BY expression for a field.
     * If a date truncation is specified, wraps the field in the corresponding SOQL date
     * function.
     *
     * The truncation is applied whenever the admin sets it — we deliberately do NOT gate
     * on the describe-detected field type. Data Cloud DMO describe is unreliable and often
     * reports a real datetime field as a non-date type; the old type gate then fell back to
     * the raw field, producing "field <x> can not be grouped in a query call" on a correctly
     * configured date group. Honoring the admin's explicit truncation is the robust behavior.
     * Setting a truncation on a genuinely non-date field will surface a SOQL error — an
     * explicit misconfiguration, preferable to silently dropping a valid date bucket.
     */
    @TestVisible
    private static String buildGroupByExpression(String field, String trunc, Schema.DisplayType fieldType) {
        if (String.isBlank(trunc) || !VALID_DATE_TRUNCATIONS.contains(trunc)) {
            return field;
        }
        Boolean isDate = (fieldType == Schema.DisplayType.DATE);
        // Apply the appropriate SOQL date function
        switch on trunc {
            when 'year'    { return 'CALENDAR_YEAR('    + field + ')'; }
            when 'quarter' { return 'CALENDAR_QUARTER(' + field + ')'; }
            when 'month'   { return 'CALENDAR_MONTH('   + field + ')'; }
            when 'week'    { return 'WEEK_IN_YEAR('      + field + ')'; }
            when 'day'     {
                // DAY_ONLY converts DATETIME to Date; DATE fields are already day-level
                return isDate ? field : 'DAY_ONLY(' + field + ')';
            }
        }
        return field;
    }

    /**
     * Builds the ANSI-SQL date-bucketing query for the Data Cloud Query API.
     * Used only when a Group By Truncation is set. SELECT shape is positional:
     *   [ DATE_TRUNC(unit, field) AS bucket, <agg> AS aggval, (<stackField> AS stackval) ]
     * COUNT uses COUNT(*) (no Id-field assumption); other aggregates use the agg field.
     * Field names are regex-validated upstream; literals are escaped via ansiLiteral.
     */
    @TestVisible
    private static String buildAnsiBucketSql(QueryParams params, String dir, Integer maxGroups) {
        String unit       = params.groupByTrunc.toLowerCase();
        String bucketExpr = 'DATE_TRUNC(\'' + unit + '\', ' + params.groupByField + ')';
        String aggExpr    = (params.aggregateFunction == 'COUNT')
            ? 'COUNT(*)'
            : params.aggregateFunction + '(' + params.aggregateField + ')';

        String selectPart = bucketExpr + ' AS bucket, ' + aggExpr + ' AS aggval';
        String groupPart  = bucketExpr;
        if (String.isNotBlank(params.stackByField)) {
            selectPart += ', ' + params.stackByField + ' AS stackval';
            groupPart  += ', ' + params.stackByField;
        }

        String whereClause = params.targetField + ' = ' + ansiLiteral(params.sourceValue);
        if (params.filters != null) {
            for (FilterCondition fc : params.filters) {
                if (fc == null) continue;
                whereClause += ' AND ' + buildAnsiFilterClause(fc);
            }
        }

        // ORDER BY the output alias — bucket for chronological/groupBy sort, else the aggregate.
        String orderCol = 'groupBy'.equalsIgnoreCase(params.sortBy) ? 'bucket' : 'aggval';

        return 'SELECT ' + selectPart
             + ' FROM '     + params.targetObject
             + ' WHERE '    + whereClause
             + ' GROUP BY ' + groupPart
             + ' ORDER BY ' + orderCol + ' ' + dir
             + ' LIMIT '    + maxGroups;
    }

    /**
     * ANSI-SQL variant of buildFilterClause. Same operators, but null checks use
     * IS [NOT] NULL and string literals are escaped for ANSI (single quotes doubled).
     */
    @TestVisible
    private static String buildAnsiFilterClause(FilterCondition fc) {
        String field = fc.field;
        String op    = fc.operator;

        if (op == 'notnull') return field + ' IS NOT NULL';
        if (op == 'isnull')  return field + ' IS NULL';

        if (op == 'in') {
            List<String> parts = fc.value != null ? fc.value.split(';') : new List<String>();
            List<String> formatted = new List<String>();
            for (String p : parts) {
                formatted.add(ansiValue(p.trim()));
            }
            return field + ' IN (' + String.join(formatted, ', ') + ')';
        }

        String soqlOp;
        switch on op {
            when 'eq'   { soqlOp = '='; }
            when 'neq'  { soqlOp = '!='; }
            when 'gt'   { soqlOp = '>'; }
            when 'gte'  { soqlOp = '>='; }
            when 'lt'   { soqlOp = '<'; }
            when 'lte'  { soqlOp = '<='; }
            when 'like' { soqlOp = 'LIKE'; }
            when else   { soqlOp = '='; }
        }
        return field + ' ' + soqlOp + ' ' + ansiValue(fc.value);
    }

    /** Numeric values unquoted; everything else as an escaped ANSI string literal. */
    @TestVisible
    private static String ansiValue(String val) {
        if (val == null) return 'NULL';
        try {
            Decimal.valueOf(val);
            return val;
        } catch (Exception e) {
            return ansiLiteral(val);
        }
    }

    /** ANSI string literal: escape single quotes by doubling (Trino), wrap in quotes. */
    @TestVisible
    private static String ansiLiteral(String val) {
        if (val == null) return 'NULL';
        return '\'' + val.replace('\'', '\'\'') + '\'';
    }

    /**
     * Converts a validated FilterCondition into a SOQL predicate fragment.
     *
     * Field and operator have already been allowlisted above. String values are escaped
     * with String.escapeSingleQuotes(). Numeric values are left unquoted — Data Cloud
     * (and standard Salesforce SOQL) require numeric literals without quotes; quoting them
     * causes a "must be of type double and should not be enclosed in quotes" error.
     */
    @TestVisible
    private static String buildFilterClause(FilterCondition fc) {
        String field = fc.field;
        String op    = fc.operator;

        if (op == 'notnull') return field + ' != null';
        if (op == 'isnull')  return field + ' = null';

        // For `in`, value is semicolon-delimited: 'Val1;Val2;Val3' or '100;200;300'
        if (op == 'in') {
            List<String> parts = fc.value != null ? fc.value.split(';') : new List<String>();
            List<String> formatted = new List<String>();
            for (String p : parts) {
                formatted.add(formatFilterValue(p.trim()));
            }
            return field + ' IN (' + String.join(formatted, ', ') + ')';
        }

        String soqlOp;
        switch on op {
            when 'eq'   { soqlOp = '='; }
            when 'neq'  { soqlOp = '!='; }
            when 'gt'   { soqlOp = '>'; }
            when 'gte'  { soqlOp = '>='; }
            when 'lt'   { soqlOp = '<'; }
            when 'lte'  { soqlOp = '<='; }
            when 'like' { soqlOp = 'LIKE'; }
            when else   { soqlOp = '='; }
        }
        return field + ' ' + soqlOp + ' ' + formatFilterValue(fc.value);
    }

    /**
     * Returns the SOQL literal for a filter value.
     * Numeric values are returned as-is (no quotes) — quoting them in Data Cloud SOQL
     * causes a type mismatch error on numeric/currency fields.
     * Everything else is single-quoted with injection escaping.
     */
    @TestVisible
    private static String formatFilterValue(String val) {
        if (val == null) return 'null';
        try {
            Decimal.valueOf(val);
            return val; // safe numeric literal — no quotes
        } catch (Exception e) {
            return '\'' + String.escapeSingleQuotes(val) + '\'';
        }
    }
}
