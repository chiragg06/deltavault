import { LightningElement, track } from 'lwc';
import getComponentsPage from '@salesforce/apex/DV_VaultApi.getComponentsPage';
import getVersionsForBase from '@salesforce/apex/DV_VaultApi.getVersionsForBase';
import getSnapshotsForVersion from '@salesforce/apex/DV_VaultApi.getSnapshotsForVersion';
import getContributors from '@salesforce/apex/DV_VaultApi.getContributors';
import trackAndIngestBase from '@salesforce/apex/DV_AdminApi.trackAndIngestBase';
import runPollerNowApex from '@salesforce/apex/DV_AdminApi.runPollerNow';
import startSchedulerApex from '@salesforce/apex/DV_AdminApi.startScheduler';
import stopSchedulerApex from '@salesforce/apex/DV_AdminApi.stopScheduler';

export default class DeltavaultApp extends LightningElement {
    // Stage control: 'door' → 'selector' → 'timeline'
    @track currentStage = 'door';
    
    // Filters
    family = 'OmniProcess';
    contributor = 'all';
    search = '';
    
    familyOptions = [
        { label: 'OmniScripts', value: 'OmniProcess' },
        { label: 'FlexCards', value: 'Flexcard' },
        { label: 'DataRaptors', value: 'DataMapper' }
    ];
    
    @track contributorOptions = [];
    @track componentList = [];
    listCursor = null;
    listLoading = false;
    
    // Selection state
    selectedBaseName = null;
    selectedType = null;
    selectedComponentName = null;
    
    @track versionCards = [];
    selectedVersionForHistory = null;
    
    // Timeline
    @track historyItems = [];
    tlCursor = null;
    tlLoading = false;
    tlIdSet = new Set();
    
    // View states
    showAdminPanel = false;
    expandedSnapshots = new Set();
    
    connectedCallback() {
        this.loadContributors();
    }
    
    // === STAGE GETTERS ===
    get isDoorStage() { return this.currentStage === 'door'; }
    get isSelectorStage() { return this.currentStage === 'selector'; }
    get isTimelineStage() { return this.currentStage === 'timeline'; }
    
    // === DOOR STAGE ===
    enterVault() {
        this.currentStage = 'selector';
        this.fetchComponentList(true);
    }
    
    // === COMPONENT SELECTOR STAGE ===
    async loadContributors() {
        try {
            const result = await getContributors({ family: this.family });
            this.contributorOptions = result || [];
        } catch(e) {
            console.error('loadContributors error:', e);
        }
    }
    
    async fetchComponentList(reset = false) {
        if (this.listLoading) return;
        this.listLoading = true;
        
        try {
            const page = await getComponentsPage({
                family: this.family,
                contributor: this.contributor,
                search: this.search,
                pageSize: 50,
                cursor: reset ? null : this.listCursor
            });
            
            if (reset) this.componentList = [];
            this.componentList = [...this.componentList, ...(page.items || [])];
            this.listCursor = page.nextCursor || null;
        } catch(e) {
            console.error('fetchComponentList error:', e);
        } finally {
            this.listLoading = false;
        }
    }
    
    get dedupedComponents() {
        const map = new Map();
        for (const r of this.componentList) {
            const key = r.baseName || r.name;
            if (!map.has(key)) map.set(key, r);
        }
        return Array.from(map.values());
    }
    
    handleListScroll(e) {
        const el = e.currentTarget;
        if (el.scrollTop + el.clientHeight >= el.scrollHeight - 32) {
            if (this.listCursor && !this.listLoading) {
                this.fetchComponentList(false);
            }
        }
    }
    
    onSearchChange(e) {
        this.search = e.detail.value || '';
        this.listCursor = null;
        this.componentList = [];
        this.fetchComponentList(true);
    }
    
    async onFamilyChange(e) {
        this.family = e.detail.value;
        this.contributor = 'all';
        this.listCursor = null;
        this.componentList = [];
        await this.loadContributors();
        this.fetchComponentList(true);
    }
    
    onContributorChange(e) {
        this.contributor = e.detail.value;
        this.listCursor = null;
        this.componentList = [];
        this.fetchComponentList(true);
    }
    
    // Select component → load versions → show version cards
    async selectComponent(e) {
        this.selectedBaseName = e.currentTarget.dataset.basename;
        this.selectedType = e.currentTarget.dataset.type;
        this.selectedComponentName = e.currentTarget.dataset.name;
        
        await this.loadVersionCards();
    }
    
    async loadVersionCards() {
        this.versionCards = [];
        
        try {
            const versions = await getVersionsForBase({
                baseName: this.selectedBaseName,
                omniType: this.selectedType || this.family
            });
            
            this.versionCards = (versions || []).map(v => ({
                version: v,
                label: `Version ${v}`
            }));
        } catch(e) {
            console.error('loadVersionCards error:', e);
        }
    }
    
    get showVersionCards() {
        return this.selectedBaseName && this.versionCards.length > 0;
    }
    
    // === VERSION TIMELINE STAGE ===
    async viewVersionHistory(e) {
        this.selectedVersionForHistory = e.currentTarget.dataset.version;
        this.currentStage = 'timeline';
        await this.loadTimeline(true);
    }
    
    async loadTimeline(reset = false) {
        if (!this.selectedBaseName || !this.selectedVersionForHistory) return;
        if (this.tlLoading) return;
        
        this.tlLoading = true;
        
        try {
            const page = await getSnapshotsForVersion({
                baseName: this.selectedBaseName,
                omniType: this.selectedType || this.family,
                version: parseFloat(this.selectedVersionForHistory),
                contributor: this.contributor,
                pageSize: 25,
                cursor: reset ? null : this.tlCursor
            });
            
            const incoming = (page.items || [])
                .map(x => ({
                    ...x,
                    isExpanded: false,
                    formattedDate: this.formatDate(x.at)
                }))
                .filter(x => !this.tlIdSet.has(x.id));
            
            incoming.forEach(x => this.tlIdSet.add(x.id));
            
            if (reset) {
                this.historyItems = [];
                this.expandedSnapshots.clear();
            }
            
            this.historyItems = [...this.historyItems, ...incoming];
            this.tlCursor = page.nextCursor || null;
        } catch(e) {
            console.error('loadTimeline error:', e);
        } finally {
            this.tlLoading = false;
        }
    }
    
    handleTimelineScroll(e) {
        const el = e.currentTarget;
        if (el.scrollTop + el.clientHeight >= el.scrollHeight - 40) {
            if (this.tlCursor && !this.tlLoading) {
                this.loadTimeline(false);
            }
        }
    }
    
    formatDate(dateValue) {
        if (!dateValue) return '';
        const d = new Date(dateValue);
        return d.toLocaleString('en-US', {
            year: 'numeric', month: 'short', day: '2-digit',
            hour: '2-digit', minute: '2-digit'
        });
    }
    
    toggleSnapshot(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.historyItems.find(x => x.id === id);
        if (item) {
            item.isExpanded = !item.isExpanded;
            this.historyItems = [...this.historyItems];
        }
    }
    
    get expandLabel() {
        return 'View Details';
    }
    
    copyDiff(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.historyItems.find(x => x.id === id);
        if (item && item.diffText) {
            navigator.clipboard.writeText(item.diffText);
        }
    }
    
    copyJson(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.historyItems.find(x => x.id === id);
        if (item && item.rawJson) {
            navigator.clipboard.writeText(item.rawJson);
        }
    }
    
    backToSelector() {
        this.currentStage = 'selector';
        this.selectedBaseName = null;
        this.selectedType = null;
        this.selectedComponentName = null;
        this.versionCards = [];
        this.selectedVersionForHistory = null;
        this.historyItems = [];
        this.tlIdSet.clear();
    }
    
    backToVersions() {
        this.currentStage = 'selector';
        this.selectedVersionForHistory = null;
        this.historyItems = [];
        this.tlIdSet.clear();
    }
    
    // === ADMIN ===
    toggleAdminPanel() {
        this.showAdminPanel = !this.showAdminPanel;
    }
    
    async trackAndIngestBase() {
        if (!this.selectedBaseName) return;
        try {
            await trackAndIngestBase({
                family: this.selectedType || this.family,
                baseName: this.selectedBaseName
            });
            await this.loadVersionCards();
        } catch(e) {
            console.error('trackAndIngestBase error:', e);
        }
    }
    
    async runPollerNow() {
        try {
            await runPollerNowApex({ lookbackMinutes: 60 });
            if (this.selectedBaseName && this.selectedVersionForHistory) {
                await this.loadTimeline(true);
            }
        } catch(e) {
            console.error('runPollerNow error:', e);
        }
    }
    
    async startScheduler() {
        try {
            await startSchedulerApex({ everyMinutes: 5 });
        } catch(e) {
            console.error('startScheduler error:', e);
        }
    }
    
    async stopScheduler() {
        try {
            await stopSchedulerApex();
        } catch(e) {
            console.error('stopScheduler error:', e);
        }
    }
}