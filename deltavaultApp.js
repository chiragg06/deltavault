import { LightningElement, track } from 'lwc';
import getComponentsPage from '@salesforce/apex/DV_VaultApi.getComponentsPage';
import getVersionsForBase from '@salesforce/apex/DV_VaultApi.getVersionsForBase';
import getSnapshotsForVersion from '@salesforce/apex/DV_VaultApi.getSnapshotsForVersion';
import vaultIcon from '@salesforce/resourceUrl/vault_icon';

export default class DeltavaultApp extends LightningElement {
    // Stage: 'entry' → 'home' → 'vault'
    @track currentStage = 'entry';
    
    // Static resource
    vaultIconUrl = vaultIcon;
    iconError = false;
    
    // Filters
    family = 'OmniProcess';
    search = '';
    
    // Component list (deduplicated by BaseName)
    @track componentList = [];
    listCursor = null;
    listLoading = false;
    
    // Selected component
    selectedBaseName = null;
    selectedType = null;
    selectedComponentName = null;
    
    // Version cards for right panel
    @track versionCards = [];
    
    // Selected version for history view
    selectedVersion = null;
    
    // History/Timeline
    @track historyItems = [];
    tlCursor = null;
    tlLoading = false;
    
    // Active tab: 'notes' | 'diff' | 'raw' | 'timeline'
    @track activeTab = 'notes';
    
    // Status
    @track statusText = 'Ready';
    
    // Expanded snapshots
    expandedSet = new Set();
    
    connectedCallback() {
        // Start on entry screen
    }
    
    // === STAGE GETTERS ===
    get isEntryStage() { return this.currentStage === 'entry'; }
    get isHomeStage() { return this.currentStage === 'home'; }
    get isVaultStage() { return this.currentStage === 'vault'; }
    
    handleIconError() {
        this.iconError = true;
        this.vaultIconUrl = null;
    }
    
    // === ENTRY STAGE ===
    enterVault() {
        this.currentStage = 'home';
    }
    
    // === HOME STAGE ===
    selectFamily(e) {
        this.family = e.currentTarget.dataset.family;
        this.currentStage = 'vault';
        this.fetchComponentList(true);
    }
    
    // === VAULT STAGE ===
    async fetchComponentList(reset = false) {
        if (this.listLoading) return;
        this.listLoading = true;
        
        try {
            const page = await getComponentsPage({
                family: this.family,
                contributor: 'all',
                search: this.search,
                pageSize: 50,
                cursor: reset ? null : this.listCursor
            });
            
            if (reset) {
                this.componentList = [];
            }
            
            this.componentList = [...this.componentList, ...(page.items || [])];
            this.listCursor = page.nextCursor || null;
            this.statusText = 'Ready';
        } catch(e) {
            console.error('fetchComponentList error:', e);
            this.statusText = 'Error loading components';
        } finally {
            this.listLoading = false;
        }
    }
    
    // Get unique components (deduplicated by BaseName)
    get uniqueComponents() {
        const map = new Map();
        for (const comp of this.componentList) {
            const key = comp.baseName;
            if (!map.has(key)) {
                map.set(key, comp);
            }
        }
        return Array.from(map.values());
    }
    
    handleListScroll(e) {
        const el = e.currentTarget;
        if (el.scrollTop + el.clientHeight >= el.scrollHeight - 50) {
            if (this.listCursor && !this.listLoading) {
                this.fetchComponentList(false);
            }
        }
    }
    
    onSearchChange(e) {
        this.search = e.detail.value || '';
        this.listCursor = null;
        this.fetchComponentList(true);
    }
    
    async selectComponent(e) {
        this.selectedBaseName = e.currentTarget.dataset.basename;
        this.selectedType = e.currentTarget.dataset.type;
        this.selectedComponentName = e.currentTarget.dataset.basename;
        
        // Clear previous selection
        this.selectedVersion = null;
        this.historyItems = [];
        this.versionCards = [];
        this.activeTab = 'notes';
        
        await this.loadVersionCards();
    }
    
    async loadVersionCards() {
        this.versionCards = [];
        
        try {
            const versions = await getVersionsForBase({
                baseName: this.selectedBaseName,
                omniType: this.selectedType
            });
            
            this.versionCards = (versions || []).map(v => ({
                version: v,
                label: `v${v}`
            }));
        } catch(e) {
            console.error('loadVersionCards error:', e);
        }
    }
    
    get hasSelectedComponent() {
        return this.selectedBaseName != null;
    }
    
    async selectVersion(e) {
        this.selectedVersion = parseFloat(e.currentTarget.dataset.version);
        this.historyItems = [];
        this.tlCursor = null;
        this.activeTab = 'notes';
        await this.loadHistory(true);
    }
    
    async loadHistory(reset = false) {
        if (!this.selectedBaseName || !this.selectedVersion) return;
        if (this.tlLoading) return;
        
        this.tlLoading = true;
        this.statusText = 'Loading history...';
        
        try {
            const page = await getSnapshotsForVersion({
                baseName: this.selectedBaseName,
                omniType: this.selectedType,
                version: this.selectedVersion,
                contributor: 'all',
                pageSize: 30,
                cursor: reset ? null : this.tlCursor
            });
            
            const incoming = (page.items || []).map(x => ({
                ...x,
                isExpanded: false,
                formattedDate: this.formatDateTime(x.at)
            }));
            
            if (reset) {
                this.historyItems = [];
                this.expandedSet.clear();
            }
            
            this.historyItems = [...this.historyItems, ...incoming];
            this.tlCursor = page.nextCursor || null;
            this.statusText = 'Ready';
            
            // Render AI notes after DOM update
            setTimeout(() => this.renderAiNotes(), 100);
        } catch(e) {
            console.error('loadHistory error:', e);
            this.statusText = 'Error loading history';
        } finally {
            this.tlLoading = false;
        }
    }
    
    renderAiNotes() {
        this.historyItems.forEach(snap => {
            const el = this.template.querySelector(`.notes[data-id="${snap.id}"]`);
            if (el && snap.aiNotesHtml && !el.dataset.rendered) {
                el.innerHTML = snap.aiNotesHtml;
                el.dataset.rendered = 'true';
            }
        });
    }
    
    formatDateTime(dt) {
        if (!dt) return '';
        try {
            const d = new Date(dt);
            return d.toLocaleString('en-US', {
                year: 'numeric', month: 'short', day: '2-digit',
                hour: '2-digit', minute: '2-digit'
            });
        } catch(e) {
            return dt;
        }
    }
    
    handleMainScroll(e) {
        const el = e.currentTarget;
        if (el.scrollTop + el.clientHeight >= el.scrollHeight - 50) {
            if (this.tlCursor && !this.tlLoading) {
                this.loadHistory(false);
            }
        }
    }
        async loadVersionCards() {
        this.versionCards = [];
        this.statusText = 'Loading versions...';
        
        console.log('loadVersionCards called for:', this.selectedBaseName, this.selectedType);
        
        try {
            const versions = await getVersionsForBase({
                baseName: this.selectedBaseName,
                omniType: this.selectedType
            });
            
            console.log('Versions returned:', versions);
            
            if (!versions || versions.length === 0) {
                console.warn('No versions found for', this.selectedBaseName);
                this.statusText = 'No versions found';
                return;
            }
            
            this.versionCards = (versions || []).map(v => ({
                version: v,
                label: `v${v}`
            }));
            
            this.statusText = 'Ready';
            console.log('Version cards created:', this.versionCards.length);
        } catch(e) {
            console.error('loadVersionCards error:', e);
            this.statusText = 'Error loading versions: ' + e.body?.message || e.message;
        }
    }
    
    // === TABS ===
    switchTab(e) {
        this.activeTab = e.currentTarget.dataset.tab;
    }
    
    get showNotes() { return this.activeTab === 'notes'; }
    get showDiff() { return this.activeTab === 'diff'; }
    get showRaw() { return this.activeTab === 'raw'; }
    get showTimeline() { return this.activeTab === 'timeline'; }
    
    get notesTabClass() { return this.activeTab === 'notes' ? 'active' : ''; }
    get diffTabClass() { return this.activeTab === 'diff' ? 'active' : ''; }
    get rawTabClass() { return this.activeTab === 'raw' ? 'active' : ''; }
    get timelineTabClass() { return this.activeTab === 'timeline' ? 'active' : ''; }
    
    // === SNAPSHOT EXPAND/COLLAPSE ===
    toggleSnapshot(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.historyItems.find(x => x.id === id);
        if (item) {
            item.isExpanded = !item.isExpanded;
            if (item.isExpanded) {
                this.expandedSet.add(id);
            } else {
                this.expandedSet.delete(id);
            }
            this.historyItems = [...this.historyItems];
        }
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
    
    backToHome() {
        this.currentStage = 'home';
        this.componentList = [];
        this.selectedBaseName = null;
        this.selectedType = null;
        this.selectedComponentName = null;
        this.selectedVersion = null;
        this.versionCards = [];
        this.historyItems = [];
    }
    
    async refresh() {
        if (this.selectedBaseName && this.selectedVersion) {
            await this.loadHistory(true);
        } else if (this.currentStage === 'vault') {
            await this.fetchComponentList(true);
        }
    }
}