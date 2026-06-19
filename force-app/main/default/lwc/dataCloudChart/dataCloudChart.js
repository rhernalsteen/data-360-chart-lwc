import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import chartJs from '@salesforce/resourceUrl/ChartJS';
import fetchChartDataJson from '@salesforce/apex/DataCloudChartController.fetchChartDataJson';

const STATE = {
    UNCONFIGURED: 'UNCONFIGURED',
    LOADING:      'LOADING',
    ERROR:        'ERROR',
    EMPTY:        'EMPTY',
    HAS_DATA:     'HAS_DATA'
};

const VALID_AGGREGATES  = new Set(['SUM', 'COUNT', 'AVG', 'MIN', 'MAX']);
const VALID_CHART_TYPES = new Set(['verticalBar', 'horizontalBar', 'pie', 'line', 'donut', 'kpi']);
const ALLOWED_OPERATORS = new Set(['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'in', 'notnull', 'isnull']);
const VALID_DATE_TRUNCS = new Set(['day', 'week', 'month', 'quarter', 'year']);

const CHART_COLORS = [
    '#1589EE', '#04844B', '#FFB75D', '#E4002B', '#7B5EA7',
    '#00A9AC', '#F49542', '#16325C', '#54698D', '#A8B7C7'
];

const MONTH_LABELS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class DataCloudChart extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api componentTitle = 'Chart';

    _targetObject;
    @api set targetObject(v) { this._targetObject = v ? String(v).trim() : null; this._maybeRefetch(); }
    get  targetObject() { return this._targetObject; }

    _sourceFieldProp;
    @api set sourceField(v) { this._sourceFieldProp = v ? String(v).trim() : null; }
    get  sourceField() { return this._sourceFieldProp; }

    _targetField;
    @api set targetField(v) { this._targetField = v ? String(v).trim() : null; this._maybeRefetch(); }
    get  targetField() { return this._targetField; }

    _groupByField;
    @api set groupByField(v) { this._groupByField = v ? String(v).trim() : null; this._maybeRefetch(); }
    get  groupByField() { return this._groupByField; }

    _groupByTrunc;
    @api set groupByTrunc(v) {
        const t = v ? String(v).trim().toLowerCase() : null;
        this._groupByTrunc = VALID_DATE_TRUNCS.has(t) ? t : null;
        this._maybeRefetch();
    }
    get groupByTrunc() { return this._groupByTrunc; }

    _aggregateFunction;
    @api set aggregateFunction(v) {
        const upper = v ? String(v).trim().toUpperCase() : null;
        this._aggregateFunction = VALID_AGGREGATES.has(upper) ? upper : null;
        this._maybeRefetch();
    }
    get aggregateFunction() { return this._aggregateFunction; }

    _aggregateField;
    @api set aggregateField(v) { this._aggregateField = v ? String(v).trim() : null; this._maybeRefetch(); }
    get  aggregateField() { return this._aggregateField; }

    _stackByField;
    @api set stackByField(v) { this._stackByField = v ? String(v).trim() : null; this._maybeRefetch(); }
    get  stackByField() { return this._stackByField; }

    _stackMode = 'stacked';
    @api set stackMode(v) {
        this._stackMode = (v === 'grouped') ? 'grouped' : 'stacked';
        this._reRenderChart();
    }
    get stackMode() { return this._stackMode; }

    _sortBy = 'aggregate';
    @api set sortBy(v) { this._sortBy = (v === 'groupBy') ? 'groupBy' : 'aggregate'; this._maybeRefetch(); }
    get sortBy() { return this._sortBy; }

    _sortDirection = 'DESC';
    @api set sortDirection(v) { this._sortDirection = (v === 'ASC') ? 'ASC' : 'DESC'; this._maybeRefetch(); }
    get sortDirection() { return this._sortDirection; }

    _chartType = 'verticalBar';
    @api set chartType(v) {
        this._chartType = (v && VALID_CHART_TYPES.has(String(v))) ? String(v) : 'verticalBar';
        this._reRenderChart();
    }
    get chartType() { return this._chartType; }

    _maxGroups;
    @api set maxGroups(v) {
        const n = parseInt(v, 10);
        this._maxGroups = (!isNaN(n) && n > 0) ? Math.min(n, 100) : null;
        this._maybeRefetch();
    }
    get maxGroups() { return this._maxGroups; }

    _showLegend = null;
    @api set showLegend(v) {
        this._showLegend = (v === null || v === undefined) ? null : (v === true || v === 'true');
        this._reRenderChart();
    }
    get showLegend() { return this._showLegend; }

    _chartHeight = 300;
    @api set chartHeight(v) {
        const n = parseInt(v, 10);
        this._chartHeight = (!isNaN(n) && n > 0) ? Math.max(100, Math.min(1000, n)) : 300;
        this._reRenderChart();
    }
    get chartHeight() { return this._chartHeight; }

    _rawFilters;
    @api set filters(v) { this._rawFilters = v; this._maybeRefetch(); }
    get  filters() { return this._rawFilters; }

    _state              = STATE.UNCONFIGURED;
    _rows               = [];
    _errorMessage       = '';
    _groupByFieldLabel   = null;
    _aggregateFieldLabel = null;
    _sourceValue        = null;
    _recordData         = null;
    _fetchGeneration    = 0;
    _chart              = null;
    _chartJsInitialized = false;
    _lastRenderedGeneration = -1;

    // ---------- Source field resolution ----------

    get _sourceFieldRef() {
        return (this.objectApiName && this._sourceFieldProp)
            ? `${this.objectApiName}.${this._sourceFieldProp}`
            : null;
    }

    get _sourceFieldRefArray() {
        const refs = this._sourceFieldRef ? [this._sourceFieldRef] : [];
        for (const fieldName of this._extractPlaceholderFields()) {
            if (this.objectApiName) refs.push(`${this.objectApiName}.${fieldName}`);
        }
        return refs;
    }

    @wire(getRecord, { recordId: '$recordId', fields: '$_sourceFieldRefArray' })
    wiredRecord({ data, error }) {
        if (error) {
            this._errorMessage = 'Could not load record data.';
            this._state = STATE.ERROR;
            return;
        }
        if (!data) return;
        this._recordData = data;
        const ref = this._sourceFieldRef;
        const val = ref ? getFieldValue(data, ref) : null;
        this._sourceValue = (val !== null && val !== undefined) ? String(val) : null;
        if (!this._sourceValue) {
            this._state = STATE.EMPTY;
        } else {
            this._maybeRefetch();
        }
    }

    // ---------- Chart.js loading ----------

    connectedCallback() {
        if (!this._chartJsInitialized) {
            loadScript(this, chartJs)
                .then(() => {
                    this._chartJsInitialized = true;
                    if (this._state === STATE.HAS_DATA && this._rows.length > 0 && !this.isKpiMode) {
                        this._renderChart();
                    }
                })
                .catch(err => {
                    // eslint-disable-next-line no-console
                    console.error('[dataCloudChart] Failed to load Chart.js:', err);
                    this.dispatchEvent(new ShowToastEvent({
                        title:   'Chart.js failed to load',
                        message: 'The ChartJS static resource may not be deployed. See README for setup instructions.',
                        variant: 'error'
                    }));
                });
        }
    }

    disconnectedCallback() {
        if (this._chart) {
            this._chart.destroy();
            this._chart = null;
        }
    }

    // ---------- Configuration / fetch ----------

    _isConfigured() {
        const isKpi = this._chartType === 'kpi';
        return !!(
            this._targetObject &&
            this._targetField &&
            (isKpi || this._groupByField) &&
            this._aggregateFunction &&
            (this._aggregateFunction === 'COUNT' || this._aggregateField) &&
            this._sourceValue
        );
    }

    _maybeRefetch() {
        if (this._isConfigured()) this._fetchData();
    }

    async _fetchData() {
        const targetObject      = this._targetObject      ? String(this._targetObject)      : null;
        const targetField       = this._targetField       ? String(this._targetField)       : null;
        const sourceValue       = this._sourceValue       ? String(this._sourceValue)       : null;
        const groupByField      = this._groupByField      ? String(this._groupByField)      : null;
        const groupByTrunc      = this._groupByTrunc      ? String(this._groupByTrunc)      : null;
        const aggregateFunction = this._aggregateFunction ? String(this._aggregateFunction) : null;
        const aggregateField    = this._aggregateField    ? String(this._aggregateField)    : null;
        const stackByField      = this._stackByField      ? String(this._stackByField)      : null;
        const sortBy            = this._sortBy            ? String(this._sortBy)            : 'aggregate';
        const sortDirection     = this._sortDirection     ? String(this._sortDirection)     : 'DESC';
        const chartType         = this._chartType         ? String(this._chartType)         : null;
        const maxGroupsVal      = this._maxGroups         ? this._maxGroups                 : null;

        if (!(targetObject && targetField && aggregateFunction && sourceValue)) {
            this._state = STATE.UNCONFIGURED;
            return;
        }

        const generation = ++this._fetchGeneration;
        this._state = STATE.LOADING;
        this._groupByFieldLabel   = null;
        this._aggregateFieldLabel = null;

        const parsedFilters = this._parseFilters(this._rawFilters);

        try {
            const json = await fetchChartDataJson({
                paramsJson: JSON.stringify({
                    targetObject, targetField, sourceValue,
                    chartType,
                    groupByField, groupByTrunc,
                    aggregateFunction, aggregateField,
                    stackByField,
                    sortBy, sortDirection,
                    maxGroups: maxGroupsVal,
                    filters: parsedFilters
                })
            });

            const result = json ? JSON.parse(json) : null;
            if (generation !== this._fetchGeneration) return;

            if (result && result.rows && result.rows.length > 0) {
                this._rows               = result.rows;
                this._groupByFieldLabel   = result.groupByFieldLabel   || null;
                this._aggregateFieldLabel = result.aggregateFieldLabel || null;
                this._state = STATE.HAS_DATA;
            } else {
                this._rows  = [];
                this._state = STATE.EMPTY;
            }
        } catch (err) {
            if (generation !== this._fetchGeneration) return;
            this._errorMessage = this._resolveErrorMessage(err);
            this._state = STATE.ERROR;
        }
    }

    renderedCallback() {
        if (this._state !== STATE.HAS_DATA || !this._chartJsInitialized || this.isKpiMode) return;
        if (this._fetchGeneration === this._lastRenderedGeneration) return;
        this._lastRenderedGeneration = this._fetchGeneration;
        this._renderChart();
    }

    _reRenderChart() {
        if (this._state === STATE.HAS_DATA && this._chartJsInitialized && this._rows.length > 0 && !this.isKpiMode) {
            this._renderChart();
        }
    }

    // ---------- Filter DSL ----------

    _extractPlaceholderFields() {
        if (!this._rawFilters) return [];
        const fields = [];
        const regex = /\{([^}]+)\}/g;
        let match;
        // eslint-disable-next-line no-cond-assign
        while ((match = regex.exec(String(this._rawFilters))) !== null) {
            fields.push(match[1]);
        }
        return [...new Set(fields)];
    }

    _parseFilters(raw) {
        if (!raw) return [];
        const result = [];
        for (const token of String(raw).split(',')) {
            const t = token.trim();
            if (!t) continue;
            const parts    = t.split('|');
            if (parts.length < 2) continue;
            const field    = parts[0].trim();
            const operator = parts[1].trim().toLowerCase();
            const rawValue = parts.slice(2).join('|').trim();
            if (!field || !ALLOWED_OPERATORS.has(operator)) continue;
            result.push({ field, operator, value: this._resolvePlaceholders(rawValue) });
        }
        return result;
    }

    _resolvePlaceholders(value) {
        if (!value || !this._recordData) return value;
        return value.replace(/\{([^}]+)\}/g, (_match, fieldName) => {
            const ref = `${this.objectApiName}.${fieldName}`;
            const val = getFieldValue(this._recordData, ref);
            return (val !== null && val !== undefined) ? String(val) : '';
        });
    }

    // ---------- Chart rendering ----------

    _renderChart() {
        const canvas = this.template.querySelector('canvas');
        // eslint-disable-next-line no-undef
        if (!canvas || typeof Chart === 'undefined') return;

        if (this._chart) {
            this._chart.destroy();
            this._chart = null;
        }

        const isStacked = !!this._stackByField;
        let labels, datasets;

        if (isStacked) {
            ({ labels, datasets } = this._buildStackedDatasets(this._rows));
        } else {
            labels = this._rows.map(r => this._formatGroupLabel(r.groupValue));
            const data = this._rows.map(r => {
                const v = r.aggValue;
                return (typeof v === 'number') ? v : (parseFloat(v) || 0);
            });
            const isPieOrDonut = this._chartType === 'pie' || this._chartType === 'donut';
            datasets = [{
                label:           this._datasetLabel(),
                data,
                backgroundColor: isPieOrDonut
                    ? CHART_COLORS.slice(0, data.length)
                    : CHART_COLORS[0],
                borderColor:     this._chartType === 'line' ? CHART_COLORS[0] : undefined,
                borderWidth:     this._chartType === 'line' ? 2 : 1,
                fill:            false
            }];
        }

        const { type, options } = this._resolveChartConfig(isStacked);

        // eslint-disable-next-line no-undef
        this._chart = new Chart(canvas.getContext('2d'), {
            type,
            data: { labels, datasets },
            options
        });
    }

    _buildStackedDatasets(rows) {
        const labelSet   = [];
        const labelIndex = {};
        const stackSet   = [];
        const stackIndex = {};
        const valueMap   = {};

        for (const row of rows) {
            const g = this._formatGroupLabel(row.groupValue || '');
            const s = row.stackValue !== undefined ? String(row.stackValue || '') : '';
            const v = typeof row.aggValue === 'number' ? row.aggValue : (parseFloat(row.aggValue) || 0);

            if (!(g in labelIndex)) { labelIndex[g] = labelSet.length; labelSet.push(g); }
            if (!(s in stackIndex)) { stackIndex[s] = stackSet.length; stackSet.push(s); }
            if (!valueMap[g]) valueMap[g] = {};
            valueMap[g][s] = (valueMap[g][s] || 0) + v;
        }

        const datasets = stackSet.map((stackVal, i) => ({
            label:           stackVal || '(blank)',
            data:            labelSet.map(g => (valueMap[g] && valueMap[g][stackVal]) || 0),
            backgroundColor: CHART_COLORS[i % CHART_COLORS.length]
        }));

        return { labels: labelSet, datasets };
    }

    _formatGroupLabel(value) {
        if (!this._groupByTrunc || value === null || value === undefined) return String(value || '');
        // Date bucketing now comes from the Query API's DATE_TRUNC, which returns the
        // period-start timestamp, e.g. "2026-06-01 00:00:00.000 UTC". Parse the leading
        // Y-M-D (avoids timezone drift) and format per bucket.
        const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value));
        if (!m) return String(value);
        const year  = m[1];
        const month = parseInt(m[2], 10); // 1-12
        const day   = parseInt(m[3], 10);
        const mon   = MONTH_LABELS[month - 1] || '';
        switch (this._groupByTrunc) {
            case 'year':    return year;
            case 'quarter': return `Q${Math.floor((month - 1) / 3) + 1} ${year}`;
            case 'month':   return `${mon} ${year}`;
            case 'week':    return `Wk of ${mon} ${day}`;
            case 'day':     return `${mon} ${day}, ${year}`;
            default:        return String(value);
        }
    }

    _resolveChartConfig(isStacked = false) {
        const legendDisplay = this._effectiveLegendDisplay;
        const isHorizontal  = this._chartType === 'horizontalBar';
        const base = {
            responsive:          true,
            maintainAspectRatio: false,
            plugins: { legend: { display: legendDisplay } }
        };

        if (isStacked) {
            const axisOpts   = isHorizontal ? { indexAxis: 'y' } : {};
            const stackOpts  = this._stackMode !== 'grouped'
                ? { scales: { x: { stacked: true }, y: { stacked: true } } }
                : {};
            return { type: 'bar', options: { ...base, ...axisOpts, ...stackOpts } };
        }

        switch (this._chartType) {
            case 'horizontalBar': return { type: 'bar',      options: { ...base, indexAxis: 'y' } };
            case 'pie':           return { type: 'pie',       options: base };
            case 'donut':         return { type: 'doughnut',  options: { ...base, cutout: '60%' } };
            case 'line':          return { type: 'line',      options: base };
            default:              return { type: 'bar',       options: base };
        }
    }

    _datasetLabel() {
        const fn = this._aggregateFunction || '';
        if (fn === 'COUNT') {
            const groupLabel = this._groupByFieldLabel || this._groupByField || 'records';
            return `Count of ${groupLabel}`;
        }
        const fnLabel    = fn.charAt(0).toUpperCase() + fn.slice(1).toLowerCase();
        const fieldLabel = this._aggregateFieldLabel || this._aggregateField || 'Value';
        return `${fnLabel} of ${fieldLabel}`;
    }

    // ---------- Getters ----------

    get isKpiMode() { return this._chartType === 'kpi'; }

    get chartContainerStyle() {
        const h = (this._chartHeight && this._chartHeight > 0) ? this._chartHeight : 300;
        return `height: ${h}px;`;
    }

    get kpiValue() {
        if (!this._rows || !this._rows.length) return '—';
        const val = this._rows[0].aggValue;
        if (val === null || val === undefined) return '—';
        const num = typeof val === 'number' ? val : parseFloat(val);
        if (isNaN(num)) return String(val);
        if (Math.abs(num) >= 1e9) return `${(num / 1e9).toFixed(1)}B`;
        if (Math.abs(num) >= 1e6) return `${(num / 1e6).toFixed(1)}M`;
        if (Math.abs(num) >= 1e3) return `${(num / 1e3).toFixed(1)}K`;
        return Number.isInteger(num) ? String(num) : num.toFixed(2);
    }

    get kpiLabel() { return this._datasetLabel(); }

    get _effectiveLegendDisplay() {
        if (this._showLegend !== null && this._showLegend !== undefined) return this._showLegend;
        return this._chartType === 'pie' || this._chartType === 'donut' || !!this._stackByField;
    }

    get isUnconfigured() { return this._state === STATE.UNCONFIGURED; }
    get isLoading()      { return this._state === STATE.LOADING; }
    get isError()        { return this._state === STATE.ERROR; }
    get isEmpty()        { return this._state === STATE.EMPTY; }
    get hasData()        { return this._state === STATE.HAS_DATA; }
    get cardTitle()      { return this.componentTitle || 'Chart'; }

    // ---------- Error handling ----------

    handleRetry() { this._fetchData(); }

    _extractErrorMessage(err) {
        if (!err) return 'An unexpected error occurred.';
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return 'An unexpected error occurred.';
    }

    _isGenericPlatformError(err) {
        const msg = (err && err.body && err.body.message) ? err.body.message : (err && err.message) || '';
        return /internal server error|UNKNOWN_EXCEPTION|Error ID/i.test(msg);
    }

    _resolveErrorMessage(err) {
        const raw = this._extractErrorMessage(err);

        // Date bucketing: Data Cloud rejects SOQL date functions (CALENDAR_MONTH, etc.)
        // on DMOs. This surfaces either as an explicit "not supported" message or, more
        // often, as the opaque platform gack that bypasses Apex try/catch. When a
        // truncation is configured, that's overwhelmingly the cause — say so plainly
        // rather than blaming an unmapped field.
        const unsupportedFn = /\bnot supported\b/i.test(raw);
        if (unsupportedFn || (this._isGenericPlatformError(err) && this._groupByTrunc)) {
            return (
                `Couldn't load chart data. Date bucketing (Group By Truncation) isn't ` +
                `supported on Data Cloud objects — the underlying date functions only ` +
                `work on standard or custom objects. Remove the Group By Truncation, or ` +
                `group by a non-date field.`
            );
        }

        // Other opaque platform errors: could be an unmapped field OR an unsupported
        // operation. Don't assert one cause definitively.
        if (this._isGenericPlatformError(err)) {
            return (
                `Couldn't load chart data. A configured field may not be mapped in the ` +
                `Data Cloud data model on ${this._targetObject || 'the target object'}, ` +
                `or the query uses an operation Data Cloud doesn't support. Verify the ` +
                `Target Field, Group By, and Aggregate fields are mapped in ` +
                `Setup → Data Cloud → Data Model.`
            );
        }
        return raw;
    }
}
