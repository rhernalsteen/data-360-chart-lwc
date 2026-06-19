# Data Cloud Chart LWC

A configurable Salesforce Lightning Web Component that visualizes Data Cloud records (Data Lake Objects / Data Model Objects) as charts on any Lightning record page. Fully admin-configurable from Lightning App Builder — no code changes required to target a different DMO, change the grouping field, or switch chart types.

---

## What it does

Drop the component on a CRM record page (e.g., Account, Contact, Opportunity), point it at a Data Cloud DLM/DMO and a linking field, and it renders an aggregate chart powered by Chart.js with:

- **Six chart types:** Vertical Bar, Horizontal Bar, Pie, Donut, Line, and KPI (single large metric)
- Any GROUP BY field as the axis labels or pie slices
- **Date bucketing** on date/datetime GROUP BY fields — bucket by day, week, month, quarter, or year with auto-formatted labels (e.g. `Jun 2026`, `Q2 2026`, `Jun 5, 2026`, `Wk of Jun 1`). Runs through the Data Cloud Query API in-org — no extra setup.
- **Stacked and grouped bar charts** — add a second Stack By field to break each bar into color-coded segments
- Five aggregate functions: **SUM**, **COUNT**, **AVG**, **MIN**, **MAX**
- Sort by aggregate value or group label, ascending or descending
- Configurable max groups, chart height, and legend visibility
- Optional extra WHERE conditions via a filter DSL (supports `{FieldName}` placeholders resolved from the current record)
- A skeleton loading state and clean empty state when no groups match

The component is read-only — no DML, no callouts.

---

## Prerequisites

**Chart.js must be uploaded as a Static Resource before the component will render.**

1. Download the Chart.js UMD bundle: [https://cdn.jsdelivr.net/npm/chart.js/dist/chart.umd.min.js](https://cdn.jsdelivr.net/npm/chart.js/dist/chart.umd.min.js)
2. In the target org: **Setup → Static Resources → New**
3. Name: `ChartJS` (exact, case-sensitive), Cache Control: `Public`
4. Upload the file → Save

This is a one-time step per org. Static Resources cannot be included in unmanaged packages.

---

## Installation

| Org Type | Install URL |
|---|---|
| **Production / Developer Edition** | [https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000KnKj](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000KnKj) |
| **Sandbox** | [https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000KnKj](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000KnKj) |

Upload the `ChartJS` Static Resource (see Prerequisites above) before or after installing. See [POST_INSTALL.txt](POST_INSTALL.txt) for a step-by-step consultant setup guide.

---

## Architecture

### Component layout

```
force-app/main/default/
├── classes/
│   ├── DataCloudChartController.cls          ← @AuraEnabled Apex
│   ├── DataCloudChartController.cls-meta.xml
│   ├── DataCloudChartControllerTest.cls      ← 53 Apex tests
│   └── DataCloudChartControllerTest.cls-meta.xml
└── lwc/
    └── dataCloudChart/
        ├── dataCloudChart.js
        ├── dataCloudChart.html
        ├── dataCloudChart.css
        ├── dataCloudChart.js-meta.xml        ← App Builder properties
        └── __tests__/
            └── dataCloudChart.test.js
```

### Request flow

```
Record page loads
        │
        ▼
LWC mounts → @wire(getRecord) reads the configured Source Field on this record
        │
        ▼
Source value resolved → LWC builds params and calls @AuraEnabled Apex:
  fetchChartDataJson(paramsJson: String)
        │
        │  paramsJson includes: targetObject, targetField, sourceValue,
        │  chartType, groupByField, groupByTrunc, aggregateFunction,
        │  aggregateField, stackByField, sortBy, sortDirection,
        │  maxGroups, filters[]
        ▼
Apex → JSON.deserialize(paramsJson, QueryParams.class)
     → regex validation (Layer 1) → Schema describe (Layer 2, best-effort)
     → BUILD QUERY:
         KPI mode:       SELECT AGG(Id) FROM targetObject WHERE targetField = :sourceValue   (SOQL)
         Date bucketing: SELECT DATE_TRUNC('unit', groupByField) AS bucket, AGG(...) AS aggval
                                [, stackByField AS stackval]
                         FROM targetObject WHERE ... GROUP BY DATE_TRUNC(...) [, stackByField]
                         ORDER BY bucket|aggval ASC|DESC LIMIT maxGroups
                         → runs via ConnectApi.CdpQuery (Query API / ANSI SQL), in-org, no callout
         Standard:       SELECT groupByField, AGG(aggregateField) [, stackByField]
                         FROM targetObject WHERE targetField = :sourceValue [AND filters]
                         GROUP BY groupByField [, stackByField]
                         ORDER BY AGG(aggregateField)|groupByField ASC|DESC
                         LIMIT maxGroups (default 25, hard cap 100)   (SOQL)
        │
        ▼
Results coerced to List<Map<String, Object>>:
  { groupValue, aggValue, [stackValue], _rowKey }
        │
        ▼
JSON.serialize(result) → returned to LWC as a String
        │
        ▼
LWC JSON.parse → Chart.js renders into a <canvas> element.
  Stacked charts: rows are pivoted into one dataset per stack value.
  KPI mode: rendered as a large formatted number — no canvas used.
Chart is destroyed and re-created on every data refresh.
```

### Key design decisions

#### 1. Chart.js via Static Resource

Salesforce has no native chart base component. Chart.js is loaded once per page via `lightning/platformResourceLoader` (`loadScript`) into a `<canvas>` element. A `_chartJsInitialized` guard prevents re-loading. The chart instance is tracked in `_chart` and destroyed before each re-render to prevent canvas reuse errors. KPI mode skips the canvas entirely.

#### 2. Apex returns a JSON `String`, not a typed wrapper

Same pattern as the companion `dataCloudRelatedList` component. Data Cloud types can fail at the `@AuraEnabled` response-serialization boundary after the method returns, producing an opaque platform error that bypasses Apex `try/catch`. A `String` always serializes cleanly.

#### 3. LWC sends `paramsJson` (a JSON String), not a typed object

Lightning Web Security wraps cross-membrane parameter objects in a `SecureProxy` that can serialize nested string fields as `null`. Passing a single `String paramsJson` and deserializing server-side bypasses that entirely.

#### 4. COUNT uses `COUNT(Id)`, not `COUNT(groupByField)`

Data Cloud and standard SOQL both reject `COUNT(field)` when that field is the `GROUP BY` column ("Grouped field should not be aggregated"). `COUNT()` with no argument is also rejected in a mixed SELECT by standard SOQL. `COUNT(Id)` is unambiguous and valid in both contexts — Id is never the group-by field.

#### 5. ORDER BY repeats the full aggregate expression

Data Cloud SOQL rejects `ORDER BY` on an aggregate alias (e.g., `ORDER BY aggValue` fails with "No such column 'aggValue'"). The controller repeats the full expression: `ORDER BY SUM(ssot__TotalAmount__c) DESC`.

#### 6. Date bucketing runs through the Data Cloud Query API (ANSI SQL)

Data Cloud SOQL does **not** support date-truncation functions (`CALENDAR_MONTH`, `DAY_ONLY`, etc.) on DMOs — they only work on standard objects. So when a Group By Truncation is set, the controller builds an **ANSI SQL** query using `DATE_TRUNC('unit', field)` and runs it through `ConnectApi.CdpQuery.queryAnsiSqlV2` — in-org, **no callout or Named Credential**. The positional result rows are mapped to the same `{ groupValue, aggValue, [stackValue] }` shape the LWC consumes, and the aggregate is coerced to a number (Data Cloud can return SUM as a high-precision string). All non-bucketed charts stay on the SOQL/`AggregateResult` path. The LWC formats the `DATE_TRUNC` period-start timestamp into friendly labels (`Jun 2026`, `Q2 2026`, `Jun 5, 2026`).

#### 7. KPI mode skips GROUP BY entirely

When `chartType = 'kpi'`, the Apex controller runs a scalar aggregate query with no GROUP BY or LIMIT clause — SOQL rejects LIMIT on a non-grouped scalar aggregate. The result is a single row containing the aggregate value, formatted client-side with K/M/B abbreviations.

#### 8. Stacked charts pivot in LWC, not Apex

The Apex controller adds `stackByField` to SELECT and GROUP BY and includes `stackValue` in each result row. The LWC's `_buildStackedDatasets()` method pivots the flat rows into Chart.js's multi-dataset format (one dataset per stack value), filling gaps with zero for missing combinations.

#### 9. Two-layer field validation

- **Layer 1 (always runs):** regex pre-filter on every field name — blocks SOQL injection with zero governor cost.
- **Layer 2 (best effort):** `Schema.describeSObjects` against the DMO. Validates `groupByField`, `aggregateField`, `stackByField`, and captures the `groupByField` Display Type for date-function selection. Falls back to regex-only if the object isn't introspectable.

#### 10. Filter DSL with `{FieldName}` placeholders

Admins can configure extra WHERE conditions in App Builder using a pipe-delimited DSL:

```
ssot__Stage__c|eq|Closed Won, ssot__Amount__c|gte|100000, ssot__CloseDate__c|gte|{CloseDate}
```

`{FieldName}` tokens are resolved client-side from the `@wire(getRecord)` response before the params are sent to Apex. The resolved strings are passed as pre-evaluated values — never concatenated into SOQL. Each value is escaped via `String.escapeSingleQuotes()`; numeric values are passed unquoted.

Supported operators: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `in`, `notnull`, `isnull`.

For `in`: semicolon-separated values — `ssot__Stage__c|in|Prospecting;Closed Won`.  
For `notnull` / `isnull`: no value needed — `ssot__Amount__c|notnull`.

---

## Deployment

### One-time CLI setup

```bash
npm install -g @salesforce/cli
sf org login web --alias prod --instance-url https://login.salesforce.com
```

### Validate (dry run)

```bash
sf project deploy validate \
  --target-org prod \
  --source-dir force-app \
  --test-level RunSpecifiedTests \
  --tests DataCloudChartControllerTest
```

### Deploy

```bash
sf project deploy quick --job-id <VALIDATION_ID> --target-org prod
```

### Grant access

Users who aren't system administrators need **Apex Class Access** to `DataCloudChartController`:

- **Setup → Permission Sets** → create or edit a permission set
- **Apex Class Access** → add `DataCloudChartController`
- **Manage Assignments** → assign to the relevant users

---

## Configuration (Lightning App Builder)

### Properties

| Property | Type | Required | Description |
|---|---|:---:|---|
| **Card Title** | String | — | Header label. Defaults to "Chart". |
| **Target Object API Name** | String | ✓ | Full API name of the Data Cloud object (e.g., `ssot__Opportunity__dlm`). |
| **Source Field (CRM Record)** | String | ✓ | Field on the current CRM record whose value links to Data Cloud (e.g., `Id`). |
| **Target Field (Data Cloud)** | String | ✓ | Field on the Data Cloud record that matches the source value (e.g., `ssot__CustomerAccountId__c`). |
| **Group By Field** | String | ✓* | Field to GROUP BY — becomes axis labels or pie slices. *Not required for KPI chart type. |
| **Aggregate Function** | Picklist | ✓ | `SUM`, `COUNT`, `AVG`, `MIN`, or `MAX`. |
| **Aggregate Field** | String | — | Numeric field to aggregate (e.g., `ssot__TotalAmount__c`). Not required for COUNT. |
| **Chart Type** | Picklist | ✓ | `verticalBar`, `horizontalBar`, `pie`, `donut`, `line`, or `kpi`. |
| **Sort By** | Picklist | — | `aggregate` (default) — orders by value. `groupBy` — orders alphabetically by label. |
| **Sort Direction** | Picklist | — | `ASC` or `DESC`. Defaults to `DESC`. |
| **Group By Truncation** | Picklist | — | Buckets a date/datetime Group By Field by `day`, `week`, `month`, `quarter`, or `year` (labels like `Jun 2026`, `Q2 2026`). Runs via the Data Cloud Query API (in-org). Set only on date/datetime fields — on other types the query errors. |
| **Stack By Field** | String | — | Second GROUP BY field for stacked/grouped bar charts. Each distinct value becomes a color segment. |
| **Stack Mode** | Picklist | — | `stacked` (default) or `grouped`. Only applies when Stack By Field is set. |
| **Max Groups** | Integer | — | Maximum groups returned, 1–100. Defaults to 25. |
| **Show Legend** | Boolean | — | Override auto legend visibility. Auto-on for pie, donut, and stacked charts; auto-off otherwise. |
| **Chart Height (px)** | Integer | — | Canvas height in pixels, 100–1000. Defaults to 300. |
| **Filters** | String | — | Extra WHERE conditions. See Filter DSL above. |

### Example configurations

**Opportunity stage breakdown — pie chart on an Account page**

| Property | Value |
|---|---|
| Card Title | `Opportunities by Stage` |
| Target Object API Name | `ssot__Opportunity__dlm` |
| Source Field (CRM Record) | `Id` |
| Target Field (Data Cloud) | `ssot__CustomerAccountId__c` |
| Group By Field | `ssot__OpportunityStageId__c` |
| Aggregate Function | `SUM` |
| Aggregate Field | `ssot__TotalAmount__c` |
| Chart Type | `pie` |
| Sort Direction | `DESC` |

**Order trend by month — line chart with date bucketing**

| Property | Value |
|---|---|
| Group By Field | `ssot__OrderDate__c` *(datetime field)* |
| Group By Truncation | `month` |
| Aggregate Function | `COUNT` |
| Sort By | `groupBy` |
| Sort Direction | `ASC` |
| Chart Type | `line` |

**Total lifetime spend — KPI card**

| Property | Value |
|---|---|
| Aggregate Function | `SUM` |
| Aggregate Field | `ssot__TotalAmount__c` |
| Chart Type | `kpi` |

*(Group By Field not required in KPI mode)*

---

## How it behaves

| Situation | What you see |
|---|---|
| Initial load / refetch in progress | Skeleton loading state |
| All properties set, records found | Chart rendered in the configured type |
| All properties set, zero groups match | "No data to display" empty state |
| Source field is empty on the CRM record | Empty state — no Apex call is made |
| One or more required properties not set | "Component Not Configured" message |
| Apex error | Error state with the message |
| Chart.js fails to load | Toast error indicating the Static Resource is missing |

---

## Data Cloud limitations & quirks

| Constraint | How the component handles it |
|---|---|
| Date functions (`CALENDAR_MONTH`, `DAY_ONLY`, …) unsupported in SOQL on DMOs | Date bucketing runs through the Data Cloud Query API (ANSI SQL `DATE_TRUNC`) via `ConnectApi.CdpQuery` — in-org, no callout |
| `ORDER BY` on aggregate aliases rejected (SOQL path) | Full aggregate expression repeated in `ORDER BY` (e.g., `ORDER BY SUM(ssot__TotalAmount__c) DESC`) |
| `COUNT(groupByField)` rejected | Uses `COUNT(Id)` (SOQL) / `COUNT(*)` (Query API) |
| `LIMIT` rejected on scalar aggregate | KPI queries omit `LIMIT` — scalar aggregates always return one row |
| `HAVING` clause not reliably supported | Not used — filter before aggregation via the WHERE filter DSL |
| `Schema.describeSObjects()` may fail for some DMOs | Falls back to regex-only field validation |
| Max groups returned | Configurable 1–100 (default 25), hard-capped at 100 |

---

## Running tests

### Apex tests

```bash
sf apex run test \
  --target-org prod \
  --class-names DataCloudChartControllerTest \
  --result-format human \
  --code-coverage
```

**53 Apex tests** covering: input validation, SOQL injection prevention, sort direction, filter DSL, aggregate functions (SUM/COUNT/AVG), date bucketing (ANSI SQL builder unit tests — `buildAnsiBucketSql` / `buildAnsiFilterClause` / `ansiLiteral`), KPI mode, `stackByField` validation, `maxGroups` clamping, and the JSON wrapper. *(End-to-end date bucketing uses `ConnectApi.CdpQuery`, which can't run in data-siloed Apex tests — its SQL is unit-tested and the round-trip is validated against the org.)*

### LWC Jest tests

```bash
npm install
npm test
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Chart never renders, toast error | `ChartJS` Static Resource not uploaded | Upload `chart.umd.min.js` as a Static Resource named `ChartJS` (exact casing) |
| **"Component Not Configured"** | A required property is missing | Verify Target Object, Source Field, Target Field, Group By Field (not required for KPI), Aggregate Function, and Chart Type are all set |
| Opaque platform error or "unmapped field" message | Group By / Aggregate / Stack By field not mapped in Data Cloud data model | Remove the offending field; verify in Setup → Data Cloud → Data Model |
| **"You don't have access"** | Running user lacks Apex Class Access | Assign a permission set granting access to `DataCloudChartController` |
| Empty state despite data existing | Source field is null on the CRM record, or Target Field doesn't match | Check the source field value and verify the DMO's linking field |
| Date-bucketed chart shows an error | Group By Truncation is set on a non-date field | Truncation runs `DATE_TRUNC` via the Query API — set it only on date/datetime fields |
| Date-bucketed chart errors with a permissions message | Running user lacks Data Cloud Query API access | Date bucketing uses `ConnectApi.CdpQuery`; ensure the user has Data Cloud access (non-bucketed charts use plain SOQL and don't need it) |

---

## Companion component

This component pairs with **[Data Cloud Related List LWC](https://github.com/rhernalsteen/data-360-related-list-lwc)**, which displays the same Data Cloud records as a sortable, paginated table. Both components share the same record-linking pattern and filter DSL — they can sit side-by-side on the same Lightning page targeting the same DMO.
