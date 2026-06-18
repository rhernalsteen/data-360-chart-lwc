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
    private static final Set<String> VALID_DIRECTIONS  = new Set<String>{ 'ASC', 'DESC' };
    private static final Set<String> VALID_AGGREGATES  = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };
    private static final Set<String> ALLOWED_OPERATORS = new Set<String>{
        'eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'in', 'notnull', 'isnull'
    };
    private static final Integer MAX_GROUPS = 100;

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
        @AuraEnabled public String              sortDirection;     // ASC | DESC on aggValue
        @AuraEnabled public List<FilterCondition> filters;
    }

    public class ChartResult {
        // Each row: { groupValue: String, aggValue: Decimal/Integer, _rowKey: String }
        @AuraEnabled public List<Map<String, Object>> rows;
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

            if (String.isBlank(params.targetObject) || String.isBlank(params.targetField)) {
                throwSafe('Target object and target field are required.');
            }
            if (String.isBlank(params.groupByField)) {
                throwSafe('Group By field is required.');
            }
            if (String.isBlank(params.aggregateFunction) || !VALID_AGGREGATES.contains(params.aggregateFunction)) {
                throwSafe('Aggregate function must be one of: SUM, COUNT, AVG, MIN, MAX.');
            }
            if (params.aggregateFunction != 'COUNT' && String.isBlank(params.aggregateField)) {
                throwSafe('Aggregate field is required for ' + params.aggregateFunction + '.');
            }

            // Layer 1 — regex injection guard
            assertValidApiName(params.targetObject, 'target object');
            assertValidApiName(params.targetField, 'target field');
            assertValidApiName(params.groupByField, 'group-by field');
            if (String.isNotBlank(params.aggregateField)) {
                assertValidApiName(params.aggregateField, 'aggregate field');
            }
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
                if (fieldMap.get(params.groupByField.toLowerCase()) == null) {
                    throwSafe('Invalid group-by field: ' + params.groupByField);
                }
                if (String.isNotBlank(params.aggregateField)
                        && fieldMap.get(params.aggregateField.toLowerCase()) == null) {
                    throwSafe('Invalid aggregate field: ' + params.aggregateField);
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

            // For COUNT with no explicit aggregateField, count on the groupByField
            // (it's always non-null since it's the GROUP BY key).
            String countField = String.isNotBlank(params.aggregateField)
                ? params.aggregateField
                : params.groupByField;
            String aggExpr = (params.aggregateFunction == 'COUNT')
                ? 'COUNT(' + countField + ') aggValue'
                : params.aggregateFunction + '(' + params.aggregateField + ') aggValue';

            // Build WHERE clause. sourceValue is a bind variable; filter values
            // are escaped via String.escapeSingleQuotes() — Data Cloud objects do
            // not support Database.queryWithBinds with SYSTEM_MODE (existing gotcha).
            String whereClause = params.targetField + ' = :sourceValue';
            if (params.filters != null && !params.filters.isEmpty()) {
                for (FilterCondition fc : params.filters) {
                    if (fc == null) continue;
                    whereClause += ' AND ' + buildFilterClause(fc);
                }
            }

            String query = 'SELECT ' + params.groupByField + ', ' + aggExpr
                         + ' FROM '    + params.targetObject
                         + ' WHERE '   + whereClause
                         + ' GROUP BY ' + params.groupByField
                         + ' ORDER BY aggValue ' + dir
                         + ' LIMIT :maxGroups';

            String sourceValue = params.sourceValue;
            Integer maxGroups  = MAX_GROUPS;
            soqlForDiagnostic  = query;

            phase = 'EXECUTE_QUERY';
            // Cast to List<AggregateResult> — Data Cloud aggregate queries return
            // AggregateResult SObjects, same as standard SOQL.
            List<AggregateResult> results = (List<AggregateResult>) Database.query(query);

            phase = 'CONVERT_RESULTS';
            List<Map<String, Object>> rows = new List<Map<String, Object>>();
            Integer idx = 0;
            for (AggregateResult ar : results) {
                Map<String, Object> row = new Map<String, Object>();
                Object groupVal = ar.get(params.groupByField);
                Object aggVal   = ar.get('aggValue');
                // Defensive coercion: Data Cloud may return wrapper types;
                // stringify the group label and ensure aggValue is numeric.
                row.put('groupValue', groupVal != null ? String.valueOf(groupVal) : '');
                row.put('aggValue',   aggVal   != null ? aggVal : 0);
                row.put('_rowKey',    String.valueOf(idx));
                rows.add(row);
                idx++;
            }

            ChartResult result = new ChartResult();
            result.rows = rows;
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
     * Converts a validated FilterCondition into a SOQL predicate fragment.
     *
     * Field and operator have already been allowlisted above. Values are escaped
     * with String.escapeSingleQuotes() — the only safe approach for dynamic SOQL
     * when bind variables can't be declared statically for an unknown-count list.
     */
    @TestVisible
    private static String buildFilterClause(FilterCondition fc) {
        String field = fc.field;
        String op    = fc.operator;

        if (op == 'notnull') return field + ' != null';
        if (op == 'isnull')  return field + ' = null';

        // For `in`, value is semicolon-delimited: 'Val1;Val2;Val3'
        if (op == 'in') {
            List<String> parts = fc.value != null ? fc.value.split(';') : new List<String>();
            List<String> quoted = new List<String>();
            for (String p : parts) {
                quoted.add('\'' + String.escapeSingleQuotes(p.trim()) + '\'');
            }
            return field + ' IN (' + String.join(quoted, ', ') + ')';
        }

        String escaped = String.escapeSingleQuotes(fc.value != null ? fc.value : '');
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
        return field + ' ' + soqlOp + ' \'' + escaped + '\'';
    }
}
