import { LightningElement, track } from 'lwc';
import getComponentsPage from '@salesforce/apex/DV_VaultApi.getComponentsPage';
import getSnapshotsForComponent from '@salesforce/apex/DV_VaultApi.getSnapshotsForComponent';
import vaultIcon from '@salesforce/resourceUrl/vault_icon';

export default class DeltavaultApp extends LightningElement {
    @track currentStage = 'entry';
    
    vaultIconUrl = vaultIcon;
    iconError = false;
    
    family = 'OmniProcess';
    search = '';
    
    @track componentList = [];
    listCursor = null;
    listLoading = false;
    
    // Selected component group
    selectedBaseName = null;
    selectedType = null;
    selectedComponentName = null;
    
    // Version cards
    @track versionCards = [];
    
    // Selected specific version/component
    selectedComponentId = null;
    selectedVersion = null;
    
    // History
    @track historyItems = [];
    tlCursor = null;
    tlLoading = false;
    loadedSnapshotIds = new Set();
    lastUsedCursor = null;
    
    @track activeTab = 'notes';
    @track statusText = 'Ready';
    expandedSet = new Set();
    
    connectedCallback() {}
    
    get isEntryStage() { return this.currentStage === 'entry'; }
    get isHomeStage() { return this.currentStage === 'home'; }
    get isVaultStage() { return this.currentStage === 'vault'; }
    
    handleIconError() {
        this.iconError = true;
        this.vaultIconUrl = null;
    }
    
    enterVault() {
        this.currentStage = 'home';
    }
    
    selectFamily(e) {
        this.family = e.currentTarget.dataset.family;
        this.currentStage = 'vault';
        this.fetchComponentList(true);
    }
    
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
    
    // CLIENT-SIDE: Strip version for grouping
    stripVersionClientSide(fullName, omniType) {
        if (!fullName) return '';
        
        // DataRaptor: no stripping
        if (omniType === 'DataMapper') {
            return fullName;
        }
        
        let result = fullName.trim();
        
        // Handle "name • type vN" pattern
        if (result.includes(' • ')) {
            const parts = result.split(' • ');
            if (parts.length >= 2) {
                // Strip from name part
                let namePart = parts[0].trim();
                const typePart = parts.slice(1).join(' • ').trim();
                
                // Remove _1, _2, etc from name
                namePart = namePart.replace(/_\d+$/, '');
                
                // Reconstruct
                result = namePart + ' • ' + typePart;
            }
        } else {
            // No bullet, just strip _N
            result = result.replace(/_\d+$/, '');
        }
        
        // Also strip " vN" or " vN.M"
        result = result.replace(/\s+v\d+(\.\d+)?$/, '');
        
        return result;
    }
    
    // CLIENT-SIDE: Group components by stripped name
    get uniqueComponents() {
        const groupMap = new Map();
        
        for (const comp of this.componentList) {
            const baseName = this.stripVersionClientSide(comp.fullName, comp.type);
            
            if (!groupMap.has(baseName)) {
                groupMap.set(baseName, {
                    baseName: baseName,
                    type: comp.type,
                    components: []
                });
            }
            
            groupMap.get(baseName).components.push(comp);
        }
        
        // Convert to array and add version count
        const result = [];
        for (const [baseName, group] of groupMap) {
            result.push({
                baseName: baseName,
                type: group.type,
                versionCount: group.components.length
            });
        }
        
        return result;
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
        this.selectedComponentName
        this.selectedComponentName = this.selectedBaseName;
        
        // Clear previous selection
        this.selectedComponentId = null;
        this.selectedVersion = null;
        this.historyItems = [];
        this.versionCards = [];
        this.activeTab = 'notes';
        this.loadedSnapshotIds = new Set();
        this.lastUsedCursor = null;
        
        // Update selected state in sidebar
        this.template.querySelectorAll('.tree .item').forEach(item => {
            if (item.dataset.basename === this.selectedBaseName) {
                item.classList.add('selected');
            } else {
                item.classList.remove('selected');
            }
        });
        
        await this.loadVersionCards();
    }
    
    async loadVersionCards() {
        this.versionCards = [];
        this.statusText = 'Loading versions...';
        
        console.log('loadVersionCards: baseName=', this.selectedBaseName, 'type=', this.selectedType);
        
        try {
            // SPECIAL CASE: DataRaptor has no versions, load snapshots directly
            if (this.selectedType === 'DataMapper') {
                console.log('DataMapper detected - loading snapshots directly');
                
                // Find the DataRaptor component
                const drComp = this.componentList.find(c => 
                    c.fullName === this.selectedBaseName && c.type === 'DataMapper'
                );
                
                if (drComp) {
                    this.selectedComponentId = drComp.id;
                    this.selectedVersion = 1; // Dummy for display
                    await this.loadHistory(true);
                }
                return;
            }
            
            // For OmniProcess and Flexcard: Find all versions
            const matchingComponents = this.componentList.filter(c => {
                const stripped = this.stripVersionClientSide(c.fullName, c.type);
                return stripped === this.selectedBaseName && c.type === this.selectedType;
            });
            
            console.log('Matching components:', matchingComponents.length);
            
            if (matchingComponents.length === 0) {
                console.warn('No versions found');
                this.statusText = 'No versions found';
                return;
            }
            
            // Create version cards
            this.versionCards = matchingComponents.map(c => ({
                componentId: c.id,
                version: c.version || 1,
                label: `v${c.version || 1}`,
                fullName: c.fullName
            }));
            
            // Sort by version descending
            this.versionCards.sort((a, b) => (b.version || 0) - (a.version || 0));
            
            this.statusText = 'Ready';
            console.log('Version cards:', this.versionCards.length);
        } catch(e) {
            console.error('loadVersionCards error:', e);
            this.statusText = 'Error loading versions';
        }
    }
    
    get hasSelectedComponent() {
        return this.selectedBaseName != null;
    }
    
    async selectVersion(e) {
        this.selectedComponentId = e.currentTarget.dataset.componentid;
        this.selectedVersion = parseFloat(e.currentTarget.dataset.version);
        this.historyItems = [];
        this.tlCursor = null;
        this.loadedSnapshotIds = new Set();
        this.lastUsedCursor = null;
        this.activeTab = 'notes';
        await this.loadHistory(true);
    }
    
    async loadHistory(reset = false) {
        if (!this.selectedComponentId) return;
        if (this.tlLoading) return;
        
        const currentCursor = reset ? null : this.tlCursor;
        if (!reset && currentCursor === this.lastUsedCursor) {
            console.log('Already loaded this page, stopping pagination');
            this.tlCursor = null;
            return;
        }
        
        this.tlLoading = true;
        this.statusText = 'Loading history...';
        
        try {
            const page = await getSnapshotsForComponent({
                componentId: this.selectedComponentId,
                contributor: 'all',
                pageSize: 30,
                cursor: currentCursor
            });
            
            console.log('Loaded page:', page.items?.length || 0, 'snapshots');
            console.log('Next cursor:', page.nextCursor);
            
            // Filter by ID only to prevent exact duplicates
            const incoming = (page.items || [])
                .filter(x => {
                    if (this.loadedSnapshotIds.has(x.id)) {
                        console.log('Skipping duplicate ID:', x.id);
                        return false;
                    }
                    return true;
                })
                .map(x => {
                    this.loadedSnapshotIds.add(x.id);
                    return {
                        ...x,
                        isExpanded: false,
                        formattedDate: this.formatDateTime(x.at)
                    };
                });
            
            if (reset) {
                this.historyItems = [];
                this.expandedSet.clear();
                this.loadedSnapshotIds = new Set();
                incoming.forEach(x => this.loadedSnapshotIds.add(x.id));
            }
            
            console.log('Adding', incoming.length, 'new snapshots');
            
            if (incoming.length > 0) {
                this.historyItems = [...this.historyItems, ...incoming];
                this.lastUsedCursor = currentCursor;
                this.tlCursor = page.nextCursor || null;
            } else if (page.nextCursor) {
                console.log('No new data but cursor exists, trying next page');
                this.tlCursor = page.nextCursor;
                this.lastUsedCursor = currentCursor;
            } else {
                this.tlCursor = null;
                console.log('No more snapshots to load');
            }
            
            this.statusText = 'Ready';
            
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
        const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 50;
        
        if (atBottom && this.tlCursor && !this.tlLoading && this.selectedComponentId) {
            console.log('Near bottom, loading more snapshots...');
            this.loadHistory(false);
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
        this.selectedComponentId = null;
        this.selectedVersion = null;
        this.versionCards = [];
        this.historyItems = [];
        this.loadedSnapshotIds = new Set();
        this.lastUsedCursor = null;
    }
    
    async refresh() {
        if (this.selectedComponentId) {
            this.loadedSnapshotIds = new Set();
            this.lastUsedCursor = null;
            await this.loadHistory(true);
        } else if (this.currentStage === 'vault') {
            await this.fetchComponentList(true);
        }
    }
}