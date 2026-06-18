import { createElement } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import DataCloudChart from 'c/dataCloudChart';
import fetchChartDataJson from '@salesforce/apex/DataCloudChartController.fetchChartDataJson';

jest.mock(
    '@salesforce/apex/DataCloudChartController.fetchChartDataJson',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/resourceUrl/ChartJS',
    () => ({ default: '' }),
    { virtual: true }
);

// loadScript resolves immediately in tests; Chart.js is provided by window.Chart mock below.
jest.mock(
    'lightning/platformResourceLoader',
    () => ({ loadScript: jest.fn().mockResolvedValue() }),
    { virtual: true }
);

// ---------- Chart.js mock ----------

let mockChartInstance;
const MockChart = jest.fn().mockImplementation(() => {
    mockChartInstance = { destroy: jest.fn() };
    return mockChartInstance;
});

// jsdom does not implement canvas.getContext — mock it so _renderChart() can proceed.
// Without this, `canvas.getContext('2d')` throws and `this._chart` is never set,
// causing destroy assertions to fail.
HTMLCanvasElement.prototype.getContext = jest.fn().mockReturnValue({});

// ---------- helpers ----------

function buildElement(props = {}) {
    const el = createElement('c-data-cloud-chart', { is: DataCloudChart });
    el.recordId           = '001000000000001';
    el.objectApiName      = 'Account';
    el.componentTitle     = 'Test Chart';
    el.targetObject       = 'Foo__dlm';
    el.sourceField        = 'Id';
    el.targetField        = 'AccountId__c';
    el.groupByField       = 'Stage__c';
    el.aggregateFunction  = 'COUNT';
    el.chartType          = 'verticalBar';
    el.sortDirection      = 'DESC';
    Object.assign(el, props);
    return el;
}

function emitRecord(el, sourceFieldValue) {
    getRecord.emit({
        apiName: 'Account',
        fields: { Id: { value: sourceFieldValue } }
    });
    return Promise.resolve();
}

function jsonResult({ rows = [] } = {}) {
    return JSON.stringify({ rows });
}

const sampleRows = [
    { _rowKey: '0', groupValue: 'Closed Won', aggValue: 12 },
    { _rowKey: '1', groupValue: 'Prospecting', aggValue: 8 },
    { _rowKey: '2', groupValue: 'Needs Analysis', aggValue: 3 }
];

beforeEach(() => {
    window.Chart = MockChart;
});

afterEach(() => {
    delete window.Chart;
    jest.clearAllMocks();
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
});

const flush = () => Promise.resolve();

// ---------- render states ----------

describe('c-data-cloud-chart — render states', () => {
    it('renders unconfigured state when required props are not set', async () => {
        const el = createElement('c-data-cloud-chart', { is: DataCloudChart });
        document.body.appendChild(el);
        await flush();
        const heading = el.shadowRoot.querySelector('h3');
        expect(heading.textContent).toMatch(/Component Not Configured/);
    });

    it('shows empty state when source field resolves to null', async () => {
        const el = buildElement();
        document.body.appendChild(el);
        await flush();
        await emitRecord(el, null);
        await flush();
        const heading = el.shadowRoot.querySelector('h3');
        expect(heading.textContent).toMatch(/No data to display/);
    });

    it('renders error state when fetch rejects', async () => {
        fetchChartDataJson.mockRejectedValueOnce({ body: { message: 'BOOM' } });
        const el = buildElement();
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const heading = el.shadowRoot.querySelector('h3');
        expect(heading.textContent).toMatch(/Something went wrong/);
        const para = el.shadowRoot.querySelector('p');
        expect(para.textContent).toContain('BOOM');
    });

    it('shows unmapped-field guidance on generic platform error', async () => {
        fetchChartDataJson.mockRejectedValueOnce({
            body: { message: 'An internal server error has occurred. Error ID: 123456789 (-1719234624)' }
        });
        const el = buildElement({ targetObject: 'ssot__Opportunity__dlm' });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const para = el.shadowRoot.querySelector('p');
        expect(para.textContent).toMatch(/unmapped/i);
        expect(para.textContent).toContain('ssot__Opportunity__dlm');
    });
});

// ---------- fetch + chart rendering ----------

describe('c-data-cloud-chart — fetch and chart rendering', () => {
    it('renders a canvas and calls Chart constructor when data loads', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement();
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const canvas = el.shadowRoot.querySelector('canvas');
        expect(canvas).not.toBeNull();
        expect(MockChart).toHaveBeenCalledTimes(1);

        const [, config] = MockChart.mock.calls[0];
        expect(config.type).toBe('bar');
        expect(config.data.labels).toEqual(['Closed Won', 'Prospecting', 'Needs Analysis']);
        expect(config.data.datasets[0].data).toEqual([12, 8, 3]);
    });

    it('passes "pie" type to Chart.js for pie chart type', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({ chartType: 'pie' });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const [, config] = MockChart.mock.calls[0];
        expect(config.type).toBe('pie');
    });

    it('passes indexAxis: "y" for horizontalBar', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({ chartType: 'horizontalBar' });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const [, config] = MockChart.mock.calls[0];
        expect(config.type).toBe('bar');
        expect(config.options.indexAxis).toBe('y');
    });

    it('passes "line" type for line chart', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({ chartType: 'line' });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const [, config] = MockChart.mock.calls[0];
        expect(config.type).toBe('line');
    });

    it('destroys the existing chart before re-rendering on refetch', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement();
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        // Capture instance #1 BEFORE the second render replaces mockChartInstance.
        // The MockChart factory reassigns the outer `mockChartInstance` reference each time,
        // so asserting on it after the second render would check the wrong object.
        const firstInstance = mockChartInstance;
        expect(firstInstance).not.toBeNull();

        // Trigger a second fetch
        fetchChartDataJson.mockResolvedValueOnce(
            jsonResult({ rows: [{ _rowKey: '0', groupValue: 'New', aggValue: 5 }] })
        );
        el.sortDirection = 'ASC';
        await flush(); // resolves mock + state = HAS_DATA
        await flush(); // LWC re-renders
        await flush(); // renderedCallback fires + chart re-renders

        expect(firstInstance.destroy).toHaveBeenCalledTimes(1);
        expect(MockChart).toHaveBeenCalledTimes(2);
    });

    it('shows empty state when rows array is empty', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: [] }));
        const el = buildElement();
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const heading = el.shadowRoot.querySelector('h3');
        expect(heading.textContent).toMatch(/No data to display/);
    });
});

// ---------- Apex call parameters ----------

describe('c-data-cloud-chart — Apex call parameters', () => {
    it('sends correct params to Apex', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({
            aggregateFunction: 'SUM',
            aggregateField:    'ssot__Amount__c',
            sortDirection:     'ASC'
        });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        expect(fetchChartDataJson).toHaveBeenCalledTimes(1);
        const sent = JSON.parse(fetchChartDataJson.mock.calls[0][0].paramsJson);
        expect(sent.targetObject).toBe('Foo__dlm');
        expect(sent.targetField).toBe('AccountId__c');
        expect(sent.sourceValue).toBe('001xxxxxxxxxxxx');
        expect(sent.groupByField).toBe('Stage__c');
        expect(sent.aggregateFunction).toBe('SUM');
        expect(sent.aggregateField).toBe('ssot__Amount__c');
        expect(sent.sortDirection).toBe('ASC');
        expect(sent.sortBy).toBe('aggregate');
    });

    it('sends sortBy groupBy when set', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({ sortBy: 'groupBy', sortDirection: 'ASC' });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const sent = JSON.parse(fetchChartDataJson.mock.calls[0][0].paramsJson);
        expect(sent.sortBy).toBe('groupBy');
        expect(sent.sortDirection).toBe('ASC');
    });

    it('parses filter DSL and sends conditions to Apex', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({
            filters: 'ssot__Stage__c|eq|Closed Won, ssot__Amount__c|gte|1000'
        });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const sent = JSON.parse(fetchChartDataJson.mock.calls[0][0].paramsJson);
        expect(sent.filters).toHaveLength(2);
        expect(sent.filters[0]).toEqual({ field: 'ssot__Stage__c', operator: 'eq', value: 'Closed Won' });
        expect(sent.filters[1]).toEqual({ field: 'ssot__Amount__c', operator: 'gte', value: '1000' });
    });

    it('drops filter tokens with invalid operators', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({
            filters: 'ssot__Stage__c|BADOP|Closed Won, ssot__Amount__c|gte|1000'
        });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const sent = JSON.parse(fetchChartDataJson.mock.calls[0][0].paramsJson);
        expect(sent.filters).toHaveLength(1); // only the valid 'gte' token passes through
    });

    it('sends COUNT with no aggregateField for COUNT function', async () => {
        fetchChartDataJson.mockResolvedValueOnce(jsonResult({ rows: sampleRows }));
        const el = buildElement({ aggregateFunction: 'COUNT' });
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();
        await flush();

        const sent = JSON.parse(fetchChartDataJson.mock.calls[0][0].paramsJson);
        expect(sent.aggregateFunction).toBe('COUNT');
        // aggregateField is null/undefined for COUNT — Apex handles it
        expect(sent.aggregateField == null || sent.aggregateField === '').toBe(true);
    });
});

// ---------- race guard ----------

describe('c-data-cloud-chart — race guard', () => {
    it('discards a stale response when a newer fetch is in-flight', async () => {
        let resolveFirst;
        fetchChartDataJson
            .mockImplementationOnce(() => new Promise(r => { resolveFirst = r; }))
            .mockResolvedValueOnce(
                jsonResult({ rows: [{ _rowKey: '0', groupValue: 'Newest', aggValue: 99 }] })
            );

        const el = buildElement();
        document.body.appendChild(el);
        await emitRecord(el, '001xxxxxxxxxxxx');
        await flush();

        el.sortDirection = 'ASC'; // triggers second fetch
        await flush();
        await flush();

        // Resolve the first (stale) call — should be ignored
        resolveFirst(jsonResult({ rows: sampleRows }));
        await flush();
        await flush();

        expect(MockChart).toHaveBeenCalledTimes(1);
        const [, config] = MockChart.mock.calls[0];
        expect(config.data.labels).toEqual(['Newest']);
    });
});
