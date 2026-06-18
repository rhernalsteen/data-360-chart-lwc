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
const VALID_CHART_TYPES = new Set(['verticalBar', 'horizontalBar', 'pie', 'line']);
const ALLOWED_OPERATORS = new Set(['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'like', 'in', 'notnull', 'isnull']);

// SLDS-inspired palette so charts feel at home in a Salesforce page
const CHART_COLORS = [
    '#1589EE', '#04844B', '#FFB75D', '#E4002B', '#7B5EA7',
    '#00A9AC', '#F49542', '#16325C', '#54698D', '#A8B7C7'
];

export default class DataCloudChart extends LightningElement {
    // Provided by Lightning App Builder for record pages
    @api recordId;
    @api objectApiName;

    @api componentTitle = 'Chart';

    // Configurable @api props with setters so App Builder reconfiguration triggers refetch

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

    _sortDirection = 'DESC';
    @api set sortDirection(v) {
        this._sortDirection = (v === 'ASC') ? 'ASC' : 'DESC';
        this._maybeRefetch();
    }
    get sortDirection() { return this._sortDirection; }

    _chartType = 'verticalBar';
    @api set chartType(v) {
        this._chartType = (v && VALID_CHART_TYPES.has(String(v))) ? String(v) : 'verticalBar';
        // Re-render the chart in place if data is already loaded — no new fetch needed.
        this._reRenderChart();
    }
    get chartType() { return this._chartType; }

    _rawFilters;
    @api set filters(v) { this._rawFilters = v; this._maybeRefetch(); }
    get  filters() { return this._rawFilters; }

    // Internal reactive state
    _state              = STATE.UNCONFIGURED;
    _rows               = [];
    _errorMessage       = '';
    _sourceValue        = null;
    _recordData         = null;   // stored for placeholder resolution in filters
    _fetchGeneration    = 0;
    _chart              = null;
    _chartJsInitialized = false;
    // Guards renderedCallback so we only call Chart.js once per data fetch generation.
    _lastRenderedGeneration = -1;

    // ---------- Source field resolution via @wire(getRecord) ----------

    get _sourceFieldRef() {
        return (this.objectApiName && this._sourceFieldProp)
            ? `${this.objectApiName}.${this._sourceFieldProp}`
            : null;
    }

    get _sourceFieldRefArray() {
        const refs = this._sourceFieldRef ? [this._sourceFieldRef] : [];
        // Also pull in any fields referenced by {placeholder} in the filters DSL
        // so getRecord fetches them in the same wire call for placeholder resolution.
        for (const fieldName of this._extractPlaceholderFields()) {
            if (this.objectApiName) {
                refs.push(`${this.objectApiName}.${fieldName}`);
            }
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
                    // If data arrived before Chart.js finished loading, render now.
                    if (this._state === STATE.HAS_DATA && this._rows.length > 0) {
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
        return !!(
            this._targetObject &&
            this._targetField &&
            this._groupByField &&
            this._aggregateFunction &&
            (this._aggregateFunction === 'COUNT' || this._aggregateField) &&
            this._sourceValue
        );
    }

    _maybeRefetch() {
        if (this._isConfigured()) {
            this._fetchData();
        }
    }

    async _fetchData() {
        const targetObject      = this._targetObject      ? String(this._targetObject)      : null;
        const targetField       = this._targetField       ? String(this._targetField)       : null;
        const sourceValue       = this._sourceValue       ? String(this._sourceValue)       : null;
        const groupByField      = this._groupByField      ? String(this._groupByField)      : null;
        const aggregateFunction = this._aggregateFunction ? String(this._aggregateFunction) : null;
        const aggregateField    = this._aggregateField    ? String(this._aggregateField)    : null;
        const sortDirection     = this._sortDirection     ? String(this._sortDirection)     : 'DESC';

        if (!(targetObject && targetField && groupByField && aggregateFunction && sourceValue)) {
            this._state = STATE.UNCONFIGURED;
            return;
        }

        const generation = ++this._fetchGeneration;
        this._state = STATE.LOADING;

        const parsedFilters = this._parseFilters(this._rawFilters);

        try {
            const json = await fetchChartDataJson({
                paramsJson: JSON.stringify({
                    targetObject,
                    targetField,
                    sourceValue,
                    groupByField,
                    aggregateFunction,
                    aggregateField,
                    sortDirection,
                    filters: parsedFilters
                })
            });

            const result = json ? JSON.parse(json) : null;
            if (generation !== this._fetchGeneration) return; // stale, discard

            if (result && result.rows && result.rows.length > 0) {
                this._rows  = result.rows;
                this._state = STATE.HAS_DATA;
                // Chart is rendered in renderedCallback once the DOM updates with the canvas.
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

    // renderedCallback fires after every re-render caused by a state change.
    // We guard with _lastRenderedGeneration so Chart.js is only called once per fetch.
    renderedCallback() {
        if (this._state !== STATE.HAS_DATA || !this._chartJsInitialized) return;
        if (this._fetchGeneration === this._lastRenderedGeneration) return;
        this._lastRenderedGeneration = this._fetchGeneration;
        this._renderChart();
    }

    // Called directly when chartType changes — doesn't touch _fetchGeneration,
    // so renderedCallback won't duplicate it.
    _reRenderChart() {
        if (this._state === STATE.HAS_DATA && this._chartJsInitialized && this._rows.length > 0) {
            this._renderChart();
        }
    }

    // ---------- Filter DSL parsing ----------

    // Extracts {placeholder} field names from the raw filter string so they can be
    // included in the @wire(getRecord) fields array.
    _extractPlaceholderFields() {
        if (!this._rawFilters) return [];
        const fields = [];
        const regex = /\{([^}]+)\}/g;
        let match;
        // Using a loop is necessary with exec() to get all matches
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

    // Replaces {FieldName} tokens with the actual field value from the wired record.
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

        const labels = this._rows.map(r => r.groupValue || '');
        const data   = this._rows.map(r => {
            const v = r.aggValue;
            return (typeof v === 'number') ? v : (parseFloat(v) || 0);
        });

        const { type, options } = this._resolveChartConfig();

        // eslint-disable-next-line no-undef
        this._chart = new Chart(canvas.getContext('2d'), {
            type,
            data: {
                labels,
                datasets: [{
                    label:           this._datasetLabel(),
                    data,
                    backgroundColor: this._chartType === 'pie'
                        ? CHART_COLORS.slice(0, data.length)
                        : CHART_COLORS[0],
                    borderColor:     this._chartType === 'line' ? CHART_COLORS[0] : undefined,
                    borderWidth:     this._chartType === 'line' ? 2 : 1,
                    fill:            false
                }]
            },
            options
        });
    }

    _resolveChartConfig() {
        const base = {
            responsive:          true,
            maintainAspectRatio: false,
            plugins: {
                legend: { display: this._chartType === 'pie' }
            }
        };
        switch (this._chartType) {
            case 'horizontalBar': return { type: 'bar',  options: { ...base, indexAxis: 'y' } };
            case 'pie':           return { type: 'pie',  options: base };
            case 'line':          return { type: 'line', options: base };
            default:              return { type: 'bar',  options: base }; // verticalBar
        }
    }

    _datasetLabel() {
        const fn    = this._aggregateFunction || '';
        const field = this._aggregateField    || this._groupByField || '';
        return fn === 'COUNT'
            ? `Count of ${this._groupByField || ''}`
            : `${fn}(${field})`;
    }

    // ---------- Error handling ----------

    handleRetry() {
        this._fetchData();
    }

    _extractErrorMessage(err) {
        if (!err) return 'An unexpected error occurred.';
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return 'An unexpected error occurred.';
    }

    _isGenericPlatformError(err) {
        const msg = (err && err.body && err.body.message)
            ? err.body.message
            : (err && err.message) || '';
        return /internal server error|UNKNOWN_EXCEPTION|Error ID/i.test(msg);
    }

    _resolveErrorMessage(err) {
        if (this._isGenericPlatformError(err)) {
            return (
                `Couldn't load chart data. A configured field may be defined on ` +
                `${this._targetObject || 'the target object'} but not mapped in the ` +
                `Data Cloud data model — unmapped fields aren't queryable. ` +
                `Verify that Target Field, Group By, and Aggregate fields are all ` +
                `mapped in Setup → Data Cloud → Data Model.`
            );
        }
        return this._extractErrorMessage(err);
    }

    // ---------- State getters ----------

    get isUnconfigured() { return this._state === STATE.UNCONFIGURED; }
    get isLoading()      { return this._state === STATE.LOADING; }
    get isError()        { return this._state === STATE.ERROR; }
    get isEmpty()        { return this._state === STATE.EMPTY; }
    get hasData()        { return this._state === STATE.HAS_DATA; }

    get cardTitle() { return this.componentTitle || 'Chart'; }
}
