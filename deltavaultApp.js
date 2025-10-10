import { LightningElement, track, wire } from 'lwc';
import getComponentsPage from '@salesforce/apex/DV_VaultApi.getComponentsPage';
import getVersionsForBase from '@salesforce/apex/DV_VaultApi.getVersionsForBase';
import getSnapshotsForVersion from '@salesforce/apex/DV_VaultApi.getSnapshotsForVersion';
import getContributors from '@salesforce/apex/DV_VaultApi.getContributors';
import trackAndIngestBase from '@salesforce/apex/DV_AdminApi.trackAndIngestBase';
import runPollerNowApex from '@salesforce/apex/DV_AdminApi.runPollerNow';
import startSchedulerApex from '@salesforce/apex/DV_AdminApi.startScheduler';
import stopSchedulerApex from '@salesforce/apex/DV_AdminApi.stopScheduler';

export default class DeltavaultApp extends LightningElement {
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
    @track listItemsRaw = [];
    listCursor = null;
    listLoading = false;
    
    // Selection
    selectedBaseName = null;
    selectedType = null;
    selectedComponentName = null;
    
    @track versionOptions = [];
    selectedVersion = null;
    
    // Timeline
    @track tlItems = [];
    tlCursor = null;
    tlLoading = false;
    tlIdSet = new Set();
    
    // View states
    showAdminPanel = false;
    expandedSnapshots = new Set();
    
    connectedCallback() {
        this.loadContributors();
        this.fetchList(true);
    }
    
    // Load contributors list
    async loadContributors() {
        try {
            const result = await getContributors({ family: this.family });
            this.contributorOptions = result || [];
        } catch(e) {
            console.error('Error loading contributors:', e);
        }
    }
    
    get hasSelection() {
        return !!this.selectedBaseName;
    }
    
    get vaultTitle() {
        return `DeltaVault • ${this.familyLabel}`;
    }
    
    get familyLabel() {
        const opt = this.familyOptions.find(o => o.value === this.family);
        return opt ? opt.label : 'Components';
    }
    
    get contributorLabel() {
        const opt = this.contributorOptions.find(o => o.value === this.contributor);
        return opt ? opt.label : 'All Contributors';
    }
    
    // Fetch component list
    async fetchList(reset = false) {
        if (this.listLoading) return;
        this.listLoading = true;
        
        try {
            const page = await getComponentsPage({
                family: this.family,
                contributor: this.contributor,
                search: this.search,
                pageSize: 40,
                cursor: reset ? null : this.listCursor
            });
            
            if (reset) {
                this.listItemsRaw = [];
            }
            
            this.listItemsRaw = [...this.listItemsRaw, ...(page.items || [])];
            this.listCursor = page.nextCursor || null;
        } catch(e) {
            console.error('Error fetching list:', e);
        } finally {
            this.listLoading = false;
        }
    }
    
    // Deduplicated list (already done server-side, but keeping for safety)
    get dedupList() {
        const map = new Map();
        for (const r of this.listItemsRaw) {
            const key = r.baseName || r.name;
            if (!map.has(key)) {
                map.set(key, r);
            }
        }
        return Array.from(map.values());
    }
    
    // List scroll handler
    handleListScroll(e) {
        const el = e.currentTarget;
        if (el.scrollTop + el.clientHeight >= el.scrollHeight - 32) {
            if (this.listCursor && !this.listLoading) {
                this.fetchList(false);
            }
        }
    }
    
    // Search handler
    onSearchChange(e) {
        this.search = e.detail.value || '';
        this.listCursor = null;
        this.listItemsRaw = [];
        this.fetchList(true);
    }
    
    // Family filter handler
    async onFamilyChange(e) {
        this.family = e.detail.value;
        this.contributor = 'all';
        this.selectedBaseName = null;
        this.selectedComponentName = null;
        this.versionOptions = [];
        this.selectedVersion = null;
        this.tlItems = [];
        this.listCursor = null;
        this.listItemsRaw = [];
        
        await this.loadContributors();
        this.fetchList(true);
    }
    
    // Contributor filter handler
    onContributorChange(e) {
        this.contributor = e.detail.value;
        this.listCursor = null;
        this.listItemsRaw = [];
        this.fetchList(true);
        
        // Refresh timeline if component selected
        if (this.selectedBaseName && this.selectedVersion) {
            this.loadTimeline(true);
        }
    }
    
    // Select component
    async selectBase(e) {
        this.selectedBaseName = e.currentTarget.dataset.basename;
        this.selectedType = e.currentTarget.dataset.type;
        this.selectedComponentName = e.currentTarget.dataset.name;
        
        await this.loadVersions();
    }
    
    // Load versions for selected component
    async loadVersions() {
        this.versionOptions = [];
        this.selectedVersion = null;
        this.tlItems = [];
        this.tlIdSet.clear();
        
        try {
            const versions = await getVersionsForBase({
                baseName: this.selectedBaseName,
                omniType: this.selectedType || this.family
            });
            
            this.versionOptions = (versions || []).map(v => ({
                label: `v${v}`,
                value: v
            }));
            
            if (this.versionOptions.length) {
                this.selectedVersion = this.versionOptions[0].value;
                this.loadTimeline(true);
            } else {
                this.tlItems = [];
            }
        } catch(e) {
            console.error('Error loading versions:', e);
        }
    }
    
    // Version change handler
    async onVersionChange(e) {
        this.selectedVersion = e.detail.value;
        this.loadTimeline(true);
    }
    
    // Load timeline snapshots
    async loadTimeline(reset = false) {
        if (!this.selectedBaseName || !this.selectedVersion) return;
        if (this.tlLoading) return;
        
        this.tlLoading = true;
        
        try {
            const page = await getSnapshotsForVersion({
                baseName: this.selectedBaseName,
                omniType: this.selectedType || this.family,
                version: this.selectedVersion,
                contributor: this.contributor,
                pageSize: 20,
                cursor: reset ? null : this.tlCursor
            });
            
            const incoming = (page.items || [])
                .map(x => ({
                    ...x,
                    impacts: this.extractImpacts(x.diffText),
                    isExpanded: false,
                    formattedDate: this.formatDate(x.at),
                    // Parse AI notes to plain text for display
                    aiNotesText: this.stripHtml(x.aiNotesHtml)
                }))
                .filter(x => !this.tlIdSet.has(x.id));
            
            incoming.forEach(x => this.tlIdSet.add(x.id));
            
            if (reset) {
                this.tlItems = [];
                this.expandedSnapshots.clear();
            }
            
            this.tlItems = [...this.tlItems, ...incoming];
            this.tlCursor = page.nextCursor || null;
        } catch(e) {
            console.error('Error loading timeline:', e);
        } finally {
            this.tlLoading = false;
        }
    }
    
    // Strip HTML tags for safe display
    stripHtml(html) {
        if (!html) return '';
        // Remove HTML tags and decode entities
        const div = document.createElement('div');
        div.innerHTML = html;
        return div.textContent || div.innerText || '';
    }
    
    // Timeline scroll handler
    handleTlScroll(e) {
        const el = e.currentTarget;
        if (el.scrollTop + el.clientHeight >= el.scrollHeight - 40) {
            if (this.tlCursor && !this.tlLoading) {
                this.loadTimeline(false);
            }
        }
    }
    
    // Extract impact lines from diff
    extractImpacts(diffText) {
        if (!diffText) return [];
        
        const lines = diffText.split('\n');
        const out = [];
        
        for (const ln of lines) {
            if (!ln) continue;
            
            const interesting = 
                ln.startsWith('+ Added Elements[') || 
                ln.startsWith('~ Changed Elements[') || 
                ln.startsWith('- Removed Elements[') ||
                ln.startsWith('+ Added childPayload') || 
                ln.startsWith('~ Changed childPayload') || 
                ln.startsWith('- Removed childPayload') ||
                ln.includes('PropertySetConfig.elements[');
            
            if (interesting) {
                out.push(ln.trim());
                if (out.length >= 12) break;
            }
        }
        
        return out;
    }
    
    // Format date
    formatDate(dateValue) {
        if (!dateValue) return '';
        const d = new Date(dateValue);
        return d.toLocaleString('en-US', {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        });
    }
    
    // Toggle snapshot expansion
    toggleSnapshot(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.tlItems.find(x => x.id === id);
        if (item) {
            item.isExpanded = !item.isExpanded;
            this.tlItems = [...this.tlItems]; // Trigger reactivity
        }
    }
    
    // Copy diff to clipboard
    copyDiff(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.tlItems.find(x => x.id === id);
        if (item && item.diffText) {
            navigator.clipboard.writeText(item.diffText);
        }
    }
    
    // Copy JSON to clipboard
    copyJson(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.tlItems.find(x => x.id === id);
        if (item && item.rawJson) {
            navigator.clipboard.writeText(item.rawJson);
        }
    }
    
    // Admin actions
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
            await this.loadVersions();
        } catch(e) {
            console.error('Error ingesting:', e);
        }
    }
    
    async runPollerNow() {
        try {
            await runPollerNowApex({ lookbackMinutes: 60 });
            if (this.selectedBaseName && this.selectedVersion) {
                await this.loadTimeline(true);
            }
        } catch(e) {
            console.error('Error running poller:', e);
        }
    }
    
    async startScheduler() {
        try {
            await startSchedulerApex({ everyMinutes: 5 });
        } catch(e) {
            console.error('Error starting scheduler:', e);
        }
    }
    
    async stopScheduler() {
        try {
            await stopSchedulerApex();
        } catch(e) {
            console.error('Error stopping scheduler:', e);
        }
    }
}