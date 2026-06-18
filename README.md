# Data Cloud Chart LWC

A configurable Salesforce Lightning Web Component that visualizes Data Cloud records (Data Lake Objects / Data Model Objects) as charts on any Lightning record page. Fully admin-configurable from Lightning App Builder — no code changes required to target a different DMO, change the grouping field, or switch chart types.

---

## What it does

Drop the component on a CRM record page (e.g., Account, Contact, Opportunity), point it at a Data Cloud DLM/DMO and a linking field, and it renders an aggregate chart powered by Chart.js with:

- Four chart types: **Vertical Bar**, **Horizontal Bar**, **Pie**, **Line**
- Any GROUP BY field as the axis labels or pie slices
- Five aggregate functions: **SUM**, **COUNT**, **AVG**, **MIN**, **MAX**
- Sort by aggregate value or group label, ascending or descending
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
| **Production / Developer Edition** | [https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000Kn7p](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000Kn7p) |
| **Sandbox** | [https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000Kn7p](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tfj000000Kn7p) |

Upload the `ChartJS` Static Resource (see Prerequisites above) before or after installing.

---

## Architecture

### Component layout

```
force-app/main/default/
├── classes/
│   ├── DataCloudChartController.cls          ← @AuraEnabled Apex
│   ├── DataCloudChartController.cls-meta.xml
│   ├── DataCloudChartControllerTest.cls      ← 33 Apex tests
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
        │  groupByField, aggregateFunction, aggregateField,
        │  sortBy, sortDirection, filters[]
        ▼
Apex → JSON.deserialize(paramsJson, QueryParams.class)
     → regex validation (Layer 1) → Schema describe (Layer 2, best-effort)
     → BUILD SOQL: SELECT groupByField, AGG(aggregateField)
                   FROM targetObject
                   WHERE targetField = :sourceValue [AND filters]
                   GROUP BY groupByField
                   ORDER BY aggValue|groupByField ASC|DESC
                   LIMIT 100
        │
        ▼
Results coerced to List<Map<String, Object>> with { groupValue, aggValue, _rowKey }
        │
        ▼
JSON.serialize(result) → returned to LWC as a String
        │
        ▼
LWC JSON.parse → Chart.js renders into a <canvas> element.
Chart is destroyed and re-created on every data refresh.
```

### Key design decisions

#### 1. Chart.js via Static Resource

Salesforce has no native chart base component. Chart.js is loaded once per page via `lightning/platformResourceLoader` (`loadScript`) into a `<canvas>` element. A `_chartJsInitialized` guard prevents re-loading. The chart instance is tracked in `_chart` and destroyed before each re-render to prevent canvas reuse errors.

#### 2. Apex returns a JSON `String`, not a typed wrapper

Same pattern as the companion `dataCloudRelatedList` component. Data Cloud types can fail at the `@AuraEnabled` response-serialization boundary after the method returns, producing an opaque platform error that bypasses Apex `try/catch`. A `String` always serializes cleanly.

#### 3. LWC sends `paramsJson` (a JSON String), not a typed object

Lightning Web Security wraps cross-membrane parameter objects in a `SecureProxy` that can serialize nested string fields as `null`. Passing a single `String paramsJson` and deserializing server-side bypasses that entirely.

#### 4. COUNT uses `COUNT(Id)`, not `COUNT(groupByField)`

Data Cloud and standard SOQL both reject `COUNT(field)` when that field is the `GROUP BY` column ("Grouped field should not be aggregated"). `COUNT()` with no argument is also rejected in a mixed SELECT by standard SOQL. `COUNT(Id)` is unambiguous and valid in both contexts — Id is never the group-by field.

#### 5. ORDER BY repeats the full aggregate expression

Data Cloud SOQL rejects `ORDER BY` on an aggregate alias (e.g., `ORDER BY aggValue` fails with "No such column 'aggValue'"). The controller repeats the full expression: `ORDER BY SUM(ssot__TotalAmount__c) DESC`.

#### 6. Two-layer field validation

- **Layer 1 (always runs):** regex pre-filter on every field name — blocks SOQL injection with zero governor cost.
- **Layer 2 (best effort):** `Schema.describeSObjects` against the DMO. Validates groupByField and aggregateField against the field map. Falls back to regex-only if the object isn't introspectable.

#### 7. Filter DSL with `{FieldName}` placeholders

Admins can configure extra WHERE conditions in App Builder using a pipe-delimited DSL:

```
ssot__Stage__c|eq|Closed Won, ssot__Amount__c|gte|100000, ssot__CloseDate__c|gte|{CloseDate}
```

`{FieldName}` tokens are resolved client-side from the `@wire(getRecord)` response (the same wire that provides the source value) before the params are sent to Apex. The resolved strings are passed as pre-evaluated values — never concatenated into SOQL. Each value is escaped via `String.escapeSingleQuotes()`; numeric values are passed unquoted.

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
| **Group By Field** | String | ✓ | Field to GROUP BY — becomes axis labels or pie slices (e.g., `ssot__OpportunityStageId__c`). |
| **Aggregate Function** | Picklist | ✓ | `SUM`, `COUNT`, `AVG`, `MIN`, or `MAX`. |
| **Aggregate Field** | String | — | Numeric field to aggregate (e.g., `ssot__TotalAmount__c`). Not required for COUNT. |
| **Chart Type** | Picklist | ✓ | `verticalBar`, `horizontalBar`, `pie`, or `line`. |
| **Sort By** | Picklist | — | `aggregate` (default) — orders bars/slices by value. `groupBy` — orders alphabetically by label. |
| **Sort Direction** | Picklist | — | `ASC` or `DESC`. Defaults to `DESC`. |
| **Filters (Optional)** | String | — | Extra WHERE conditions. See Filter DSL above. |

### Example configuration (Opportunity stage breakdown on an Account page)

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
| Sort By | `aggregate` |
| Sort Direction | `DESC` |
| Filters | `ssot__TotalAmount__c\|gte\|100000` |

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
| Chart.js fails to load | Error state indicating the Static Resource is missing |

---

## Data Cloud limitations & quirks

| Constraint | How the component handles it |
|---|---|
| `ORDER BY` on aggregate aliases rejected | Full aggregate expression repeated in `ORDER BY` (e.g., `ORDER BY SUM(ssot__TotalAmount__c) DESC`) |
| `COUNT(groupByField)` rejected | Uses `COUNT(Id)` instead |
| `HAVING` clause not reliably supported | Not used — filter before aggregation via the WHERE filter DSL |
| `Schema.describeSObjects()` may fail for some DMOs | Falls back to regex-only field validation |
| Max groups returned | Hard-capped at 100 (`LIMIT 100`) |

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

**33 Apex tests** covering: input validation, SOQL injection prevention, sort direction, filter DSL, aggregate functions (SUM/COUNT/AVG), field validation, `maxGroups` cap, result shape, and the JSON wrapper.

### LWC Jest tests

```bash
npm install
npm test
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Chart never renders, spinner or blank | `ChartJS` Static Resource not uploaded | Upload `chart.umd.min.js` as a Static Resource named `ChartJS` (exact casing) |
| **"Component Not Configured"** | A required property is missing | Verify Target Object, Source Field, Target Field, Group By Field, Aggregate Function, and Chart Type are all set |
| Opaque platform error `(1850068078)` | Group By Field or Aggregate Field not queryable via Apex SOQL | Remove the offending field; verify field names in Setup → Data Cloud → Data Model |
| **"You don't have access"** | Running user lacks Apex Class Access | Assign a permission set granting access to `DataCloudChartController` |
| Empty state despite data existing | Source field is null on the CRM record, or Target Field doesn't match | Check the source field value and verify the DMO's linking field |

---

## Companion component

This component pairs with **[Data Cloud Related List LWC](https://github.com/rhernalsteen/data-360-related-list-lwc)**, which displays the same Data Cloud records as a sortable, paginated table. Both components share the same record-linking pattern and filter DSL — they can sit side-by-side on the same Lightning page targeting the same DMO.
