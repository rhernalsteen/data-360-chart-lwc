/**
 * Tests for DataCloudChartController.
 *
 * DLO/DMO records cannot be inserted in test context, so aggregate query paths
 * are exercised against the Contact standard object. Validation and helper logic
 * are tested directly via @TestVisible private methods.
 */
@IsTest
private class DataCloudChartControllerTest {

    @TestSetup
    static void setupContacts() {
        List<Contact> contacts = new List<Contact>();
        for (String dept : new List<String>{ 'Sales', 'Sales', 'Marketing', 'Marketing', 'Engineering' }) {
            contacts.add(new Contact(
                FirstName  = 'Test',
                LastName   = dept,
                Email      = 'chart@example.com',
                Department = dept
            ));
        }
        insert contacts;
    }

    private static DataCloudChartController.QueryParams baseParams() {
        DataCloudChartController.QueryParams p = new DataCloudChartController.QueryParams();
        p.targetObject      = 'Contact';
        p.targetField       = 'Email';
        p.sourceValue       = 'chart@example.com';
        p.groupByField      = 'Department';
        p.aggregateFunction = 'COUNT';
        p.aggregateField    = null;
        p.sortDirection     = 'DESC';
        p.filters           = null;
        return p;
    }

    // ---------- Guard tests ----------

    @IsTest
    static void nullParamsThrows() {
        try {
            DataCloudChartController.getChartData(null);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('configuration'));
        }
    }

    @IsTest
    static void blankTargetObjectThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        p.targetObject = '';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('required'));
        }
    }

    @IsTest
    static void blankGroupByFieldThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        p.groupByField = '';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('Group By'));
        }
    }

    @IsTest
    static void invalidAggregateFunctionThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        p.aggregateFunction = 'MEDIAN';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('Aggregate function'));
        }
    }

    @IsTest
    static void sumWithoutAggregateFieldThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        p.aggregateFunction = 'SUM';
        p.aggregateField    = null;
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('required'));
        }
    }

    // ---------- Regex injection-prevention tests ----------

    @IsTest
    static void regexRejectsInjectionInObject() {
        DataCloudChartController.QueryParams p = baseParams();
        p.targetObject = '\'; SELECT 1';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('invalid'));
        }
    }

    @IsTest
    static void regexRejectsInjectionInGroupBy() {
        DataCloudChartController.QueryParams p = baseParams();
        p.groupByField = 'Bad; DROP TABLE';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('invalid'));
        }
    }

    @IsTest
    static void regexAcceptsValidApiNameSuffixes() {
        for (String name : new List<String>{ 'Foo', 'Foo__c', 'Foo__dlm', 'Foo__dlo' }) {
            try {
                DataCloudChartController.assertValidApiName(name, 'test');
            } catch (Exception e) {
                System.assert(false, 'Regex rejected valid name: ' + name);
            }
        }
    }

    @IsTest
    static void invalidFilterOperatorThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field    = 'Department';
        fc.operator = 'INVALID';
        fc.value    = 'Sales';
        p.filters = new List<DataCloudChartController.FilterCondition>{ fc };
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('operator'));
        }
    }

    // ---------- throwSafe / AuraHandledException propagation ----------

    @IsTest
    static void auraHandledExceptionMessagePropagates() {
        try {
            DataCloudChartController.throwSafe('Test message XYZ');
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assertEquals('Test message XYZ', e.getMessage());
        }
    }

    // ---------- buildFilterClause tests ----------

    @IsTest
    static void buildFilterClauseEq() {
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Stage__c'; fc.operator = 'eq'; fc.value = 'Closed Won';
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assertEquals('Stage__c = \'Closed Won\'', clause);
    }

    @IsTest
    static void buildFilterClauseGteNumericUnquoted() {
        // Numeric values must NOT be quoted in Data Cloud SOQL — quoting causes a type error.
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Amount__c'; fc.operator = 'gte'; fc.value = '10000';
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assertEquals('Amount__c >= 10000', clause);
    }

    @IsTest
    static void buildFilterClauseEqStringQuoted() {
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Stage__c'; fc.operator = 'eq'; fc.value = 'Closed Won';
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assertEquals('Stage__c = \'Closed Won\'', clause);
    }

    @IsTest
    static void formatFilterValueNumeric() {
        System.assertEquals('42',     DataCloudChartController.formatFilterValue('42'));
        System.assertEquals('3.14',   DataCloudChartController.formatFilterValue('3.14'));
        System.assertEquals('-100',   DataCloudChartController.formatFilterValue('-100'));
    }

    @IsTest
    static void formatFilterValueString() {
        System.assertEquals('\'Sales\'', DataCloudChartController.formatFilterValue('Sales'));
    }

    @IsTest
    static void formatFilterValueNull() {
        System.assertEquals('null', DataCloudChartController.formatFilterValue(null));
    }

    @IsTest
    static void buildFilterClauseNotnull() {
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Email__c'; fc.operator = 'notnull'; fc.value = null;
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assertEquals('Email__c != null', clause);
    }

    @IsTest
    static void buildFilterClauseIsnull() {
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Phone__c'; fc.operator = 'isnull'; fc.value = null;
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assertEquals('Phone__c = null', clause);
    }

    @IsTest
    static void buildFilterClauseInStrings() {
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Stage__c'; fc.operator = 'in'; fc.value = 'Closed Won;Prospecting';
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assert(clause.startsWith('Stage__c IN ('));
        System.assert(clause.contains('\'Closed Won\''));
        System.assert(clause.contains('\'Prospecting\''));
    }

    @IsTest
    static void buildFilterClauseInNumerics() {
        // Numeric values inside IN must also be unquoted
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Amount__c'; fc.operator = 'in'; fc.value = '100;200;300';
        String clause = DataCloudChartController.buildFilterClause(fc);
        System.assert(clause.startsWith('Amount__c IN ('));
        System.assert(clause.contains('100'));
        System.assert(!clause.contains('\'100\''), 'Numeric IN values must not be quoted');
    }

    @IsTest
    static void buildFilterClauseEscapesInjection() {
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field = 'Name__c'; fc.operator = 'eq'; fc.value = '\' OR \'1\'=\'1';
        String clause = DataCloudChartController.buildFilterClause(fc);
        // The value must be escaped — no raw single quotes should survive
        System.assert(!clause.contains('\' OR \''), 'Injection payload not escaped: ' + clause);
    }

    // ---------- Aggregate query execution (against Contact) ----------

    @IsTest
    static void countQueryReturnsGroups() {
        Test.startTest();
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(baseParams()));
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.rows);
        // 3 distinct departments: Sales (2), Marketing (2), Engineering (1)
        System.assertEquals(3, result.rows.size(), 'Expected 3 department groups');
    }

    @IsTest
    static void rowsContainGroupValueAndAggValue() {
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(baseParams()));

        System.assertNotEquals(null, result.rows[0].get('groupValue'));
        System.assertNotEquals(null, result.rows[0].get('aggValue'));
        System.assertNotEquals(null, result.rows[0].get('_rowKey'));
        System.assertEquals('0', (String) result.rows[0].get('_rowKey'));
    }

    @IsTest
    static void sortDescReturnsHighestCountFirst() {
        // Sales and Marketing both have 2; Engineering has 1.
        // DESC should put Sales or Marketing first, Engineering last.
        DataCloudChartController.QueryParams p = baseParams();
        p.sortDirection = 'DESC';

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        // Last row should be Engineering (count = 1)
        Map<String, Object> lastRow = result.rows[result.rows.size() - 1];
        System.assertEquals('Engineering', (String) lastRow.get('groupValue'));
    }

    @IsTest
    static void sortAscReturnsLowestCountFirst() {
        DataCloudChartController.QueryParams p = baseParams();
        p.sortDirection = 'ASC';

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        // First row should be Engineering (count = 1)
        System.assertEquals('Engineering', (String) result.rows[0].get('groupValue'));
    }

    @IsTest
    static void sortDirectionDefaultsToDesc() {
        DataCloudChartController.QueryParams p = baseParams();
        p.sortDirection = null;

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        // Null sortDirection → DESC → Engineering last
        Map<String, Object> lastRow = result.rows[result.rows.size() - 1];
        System.assertEquals('Engineering', (String) lastRow.get('groupValue'));
    }

    @IsTest
    static void maxGroupsDefaultIs25() {
        // Default maxGroups is 25; 3 test groups should all return
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(baseParams()));
        System.assert(result.rows.size() <= 25, 'rows must not exceed default cap of 25');
        System.assertEquals(3, result.rows.size(), 'All 3 department groups should be within default limit');
    }

    @IsTest
    static void filterReducesGroups() {
        DataCloudChartController.QueryParams p = baseParams();
        DataCloudChartController.FilterCondition fc = new DataCloudChartController.FilterCondition();
        fc.field    = 'Department';
        fc.operator = 'eq';
        fc.value    = 'Sales';
        p.filters = new List<DataCloudChartController.FilterCondition>{ fc };

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        System.assertEquals(1, result.rows.size(), 'Filter should leave only Sales group');
        System.assertEquals('Sales', (String) result.rows[0].get('groupValue'));
    }

    @IsTest
    static void sourceValueBindIsSafe() {
        DataCloudChartController.QueryParams p = baseParams();
        p.sourceValue = '\' OR \'1\'=\'1';

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        // Injection payload treated as literal — no matching contacts
        System.assertEquals(0, result.rows.size());
    }

    @IsTest
    static void fetchChartDataJsonReturnsValidJson() {
        String jsonStr = DataCloudChartController.fetchChartDataJson(
            JSON.serialize(baseParams())
        );
        System.assertNotEquals(null, jsonStr);
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        System.assert(parsed.containsKey('rows'), 'JSON should include rows');
        List<Object> rows = (List<Object>) parsed.get('rows');
        System.assertEquals(3, rows.size(), 'Should have 3 department groups');
    }

    @IsTest
    static void fetchChartDataJsonPropagatesAuraError() {
        try {
            DataCloudChartController.fetchChartDataJson(null);
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('configuration'));
        }
    }

    @IsTest
    static void invalidGroupByFieldRejectedByDescribe() {
        DataCloudChartController.QueryParams p = baseParams();
        p.groupByField = 'NotARealField__c';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
    }

    // ---------- buildGroupByExpression unit tests ----------

    @IsTest
    static void groupByExprPlainFieldWhenNoTrunc() {
        String expr = DataCloudChartController.buildGroupByExpression('Department', null, null);
        System.assertEquals('Department', expr);
    }

    @IsTest
    static void groupByExprMonthFunctionForDatetime() {
        String expr = DataCloudChartController.buildGroupByExpression('CreatedDate', 'month', Schema.DisplayType.DATETIME);
        System.assertEquals('CALENDAR_MONTH(CreatedDate)', expr);
    }

    @IsTest
    static void groupByExprYearFunctionForDate() {
        String expr = DataCloudChartController.buildGroupByExpression('Birthdate', 'year', Schema.DisplayType.DATE);
        System.assertEquals('CALENDAR_YEAR(Birthdate)', expr);
    }

    @IsTest
    static void groupByExprQuarterFunction() {
        String expr = DataCloudChartController.buildGroupByExpression('CreatedDate', 'quarter', Schema.DisplayType.DATETIME);
        System.assertEquals('CALENDAR_QUARTER(CreatedDate)', expr);
    }

    @IsTest
    static void groupByExprWeekFunction() {
        String expr = DataCloudChartController.buildGroupByExpression('CreatedDate', 'week', Schema.DisplayType.DATETIME);
        System.assertEquals('WEEK_IN_YEAR(CreatedDate)', expr);
    }

    @IsTest
    static void groupByExprDayDatetime() {
        String expr = DataCloudChartController.buildGroupByExpression('CreatedDate', 'day', Schema.DisplayType.DATETIME);
        System.assertEquals('DAY_ONLY(CreatedDate)', expr);
    }

    @IsTest
    static void groupByExprDayDateIsPlainField() {
        // DATE fields are already day-level — no function needed
        String expr = DataCloudChartController.buildGroupByExpression('Birthdate', 'day', Schema.DisplayType.DATE);
        System.assertEquals('Birthdate', expr);
    }

    @IsTest
    static void groupByExprAppliesTruncRegardlessOfDetectedType() {
        // Regression: Data Cloud DMO describe often reports a real datetime field as a
        // non-date type (or not at all). The truncation must still be applied — honoring
        // the admin's explicit choice — rather than falling back to the raw field, which
        // caused "field ... can not be grouped in a query call" on a valid date group.
        String typedNonDate = DataCloudChartController.buildGroupByExpression(
            'ssot__CreatedDate__c', 'month', Schema.DisplayType.STRING);
        System.assertEquals('CALENDAR_MONTH(ssot__CreatedDate__c)', typedNonDate,
            'Truncation must apply even when describe reports a non-date type');

        String typeUnknown = DataCloudChartController.buildGroupByExpression(
            'ssot__CreatedDate__c', 'month', null);
        System.assertEquals('CALENDAR_MONTH(ssot__CreatedDate__c)', typeUnknown,
            'Truncation must apply when describe is unavailable (null type)');
    }

    // ---------- Date bucketing ----------
    // NOTE: end-to-end date bucketing now runs through the Data Cloud Query API
    // (ConnectApi.CdpQuery + DATE_TRUNC), which cannot execute in data-siloed Apex
    // tests ("ConnectApi methods are not supported in data siloed tests"). The SQL
    // construction is covered by the buildAnsiBucketSql unit tests above; the live
    // round-trip is validated manually against the org.

    @IsTest
    static void invalidGroupByTruncThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        p.groupByTrunc = 'decade';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('Truncation'));
        }
    }

    // ---------- KPI mode ----------

    @IsTest
    static void kpiModeRequiresNoGroupBy() {
        DataCloudChartController.QueryParams p = baseParams();
        p.chartType    = 'kpi';
        p.groupByField = null;  // no groupBy needed

        Test.startTest();
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(1, result.rows.size(), 'KPI should return exactly one row');
    }

    @IsTest
    static void kpiModeReturnsSingleAggValue() {
        DataCloudChartController.QueryParams p = baseParams();
        p.chartType    = 'kpi';
        p.groupByField = null;

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        Object aggVal = result.rows[0].get('aggValue');
        System.assertNotEquals(null, aggVal, 'KPI aggValue should not be null');
        // 5 contacts with chart@example.com → COUNT = 5
        System.assertEquals(5, Integer.valueOf(String.valueOf(aggVal)));
    }

    // ---------- stackByField ----------

    @IsTest
    static void invalidStackByFieldThrows() {
        DataCloudChartController.QueryParams p = baseParams();
        p.stackByField = 'Bad; DROP TABLE';
        try {
            DataCloudChartController.getChartData(JSON.serialize(p));
            System.assert(false, 'Expected exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().containsIgnoreCase('invalid'));
        }
    }

    @IsTest
    static void stackByFieldProducesStackValueInRows() {
        // Group by Department, stack by Title (null on all test contacts → one bucket per group)
        DataCloudChartController.QueryParams p = baseParams();
        p.stackByField = 'Title';  // Title is null on all test contacts → one bucket per group

        Test.startTest();
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.rows.size() > 0);
        // Each row should have a stackValue key
        System.assert(result.rows[0].containsKey('stackValue'), 'stackValue key should be present');
    }

    // ---------- maxGroups ----------

    @IsTest
    static void maxGroupsRespected() {
        // Limit to 1 group from 3 available — only 1 row should return
        DataCloudChartController.QueryParams p = baseParams();
        p.maxGroups = 1;

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        System.assertEquals(1, result.rows.size(), 'maxGroups = 1 should return only 1 row');
    }

    @IsTest
    static void maxGroupsClampedToHardCap() {
        // maxGroups > 100 should be silently clamped to 100 (no error)
        DataCloudChartController.QueryParams p = baseParams();
        p.maxGroups = 500;

        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(p));

        System.assertNotEquals(null, result);
        System.assert(result.rows.size() <= 100);
    }

    // ---------- Field labels ----------

    @IsTest
    static void resultIncludesGroupByFieldLabel() {
        // Contact.Department label is "Department"
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(baseParams()));
        System.assertEquals('Department', result.groupByFieldLabel,
            'groupByFieldLabel should match the schema label for Department');
    }

    @IsTest
    static void countResultHasNullAggregateFieldLabel() {
        // COUNT with no aggregateField — aggregateFieldLabel should be null
        DataCloudChartController.ChartResult result =
            DataCloudChartController.getChartData(JSON.serialize(baseParams()));
        System.assertEquals(null, result.aggregateFieldLabel,
            'aggregateFieldLabel should be null for COUNT with no aggregate field');
    }

    // ---------- ANSI date-bucket SQL (Query API path) ----------

    @IsTest
    static void ansiBucketSqlCountMonth() {
        DataCloudChartController.QueryParams p = baseParams();
        p.groupByField = 'CreatedDate';
        p.groupByTrunc = 'month';
        String sql = DataCloudChartController.buildAnsiBucketSql(p, 'DESC', 25);
        System.assert(sql.contains('DATE_TRUNC(\'month\', CreatedDate) AS bucket'), sql);
        System.assert(sql.contains('COUNT(*) AS aggval'), sql);
        System.assert(sql.contains('FROM Contact'), sql);
        System.assert(sql.contains('WHERE Email = \'chart@example.com\''), sql);
        System.assert(sql.contains('GROUP BY DATE_TRUNC(\'month\', CreatedDate)'), sql);
        System.assert(sql.contains('ORDER BY aggval DESC'), sql);
        System.assert(sql.endsWith('LIMIT 25'), sql);
    }

    @IsTest
    static void ansiBucketSqlSumSortByGroupWithStack() {
        DataCloudChartController.QueryParams p = baseParams();
        p.groupByField      = 'CreatedDate';
        p.groupByTrunc      = 'quarter';
        p.aggregateFunction = 'SUM';
        p.aggregateField    = 'Amount__c';
        p.stackByField      = 'Region__c';
        p.sortBy            = 'groupBy';
        String sql = DataCloudChartController.buildAnsiBucketSql(p, 'ASC', 50);
        System.assert(sql.contains('SUM(Amount__c) AS aggval'), sql);
        System.assert(sql.contains('Region__c AS stackval'), sql);
        System.assert(sql.contains('GROUP BY DATE_TRUNC(\'quarter\', CreatedDate), Region__c'), sql);
        System.assert(sql.contains('ORDER BY bucket ASC'), sql);
    }

    @IsTest
    static void ansiFilterClauseVariants() {
        DataCloudChartController.FilterCondition eqc = new DataCloudChartController.FilterCondition();
        eqc.field = 'Stage__c'; eqc.operator = 'eq'; eqc.value = 'Closed Won';
        System.assertEquals('Stage__c = \'Closed Won\'', DataCloudChartController.buildAnsiFilterClause(eqc));

        DataCloudChartController.FilterCondition gtec = new DataCloudChartController.FilterCondition();
        gtec.field = 'Amount__c'; gtec.operator = 'gte'; gtec.value = '1000';
        System.assertEquals('Amount__c >= 1000', DataCloudChartController.buildAnsiFilterClause(gtec));

        DataCloudChartController.FilterCondition nn = new DataCloudChartController.FilterCondition();
        nn.field = 'Amount__c'; nn.operator = 'notnull';
        System.assertEquals('Amount__c IS NOT NULL', DataCloudChartController.buildAnsiFilterClause(nn));

        DataCloudChartController.FilterCondition isn = new DataCloudChartController.FilterCondition();
        isn.field = 'Amount__c'; isn.operator = 'isnull';
        System.assertEquals('Amount__c IS NULL', DataCloudChartController.buildAnsiFilterClause(isn));

        DataCloudChartController.FilterCondition inc = new DataCloudChartController.FilterCondition();
        inc.field = 'Stage__c'; inc.operator = 'in'; inc.value = 'Closed Won;Prospecting';
        String clause = DataCloudChartController.buildAnsiFilterClause(inc);
        System.assert(clause.startsWith('Stage__c IN ('), clause);
        System.assert(clause.contains('\'Closed Won\''), clause);
    }

    @IsTest
    static void ansiLiteralAndValueEscaping() {
        // Single quotes doubled for ANSI (Trino), not backslash-escaped
        System.assertEquals('\'O\'\'Brien\'', DataCloudChartController.ansiLiteral('O\'Brien'));
        System.assertEquals('1000', DataCloudChartController.ansiValue('1000'));     // numeric unquoted
        System.assertEquals('\'Gold\'', DataCloudChartController.ansiValue('Gold')); // string quoted
    }

}
