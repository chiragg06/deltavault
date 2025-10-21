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
    
    selectedBaseName = null;
    selectedType = null;
    selectedComponentName = null;
    
    @track versionCards = [];
    @track versionViewMode = 'grid';
    @track versionSearch = '';
    
    selectedComponentId = null;
    selectedVersion = null;
    
    @track historyItems = [];
    tlCursor = null;
    tlLoading = false;
    loadedSnapshotIds = new Set();
    lastUsedCursor = null;
    
    @track activeTab = 'summary';
    @track statusText = 'Ready';
    
    connectedCallback() {}
    
    get isEntryStage() { return this.currentStage === 'entry'; }
    get isHomeStage() { return this.currentStage === 'home'; }
    get isVaultStage() { return this.currentStage === 'vault'; }
    
    get isGridView() { return this.versionViewMode === 'grid'; }
    get isListView() { return this.versionViewMode === 'list'; }
    
    get gridViewBtnClass() { 
        return this.versionViewMode === 'grid' ? 'view-btn active' : 'view-btn'; 
    }
    get listViewBtnClass() { 
        return this.versionViewMode === 'list' ? 'view-btn active' : 'view-btn'; 
    }
    
    get filteredVersionCards() {
        if (!this.versionSearch) {
            return this.versionCards;
        }
        
        const searchLower = this.versionSearch.toLowerCase();
        return this.versionCards.filter(vc => {
            return vc.label.toLowerCase().includes(searchLower) ||
                   (vc.fullName && vc.fullName.toLowerCase().includes(searchLower)) ||
                   (vc.latestActor && vc.latestActor.toLowerCase().includes(searchLower));
        });
    }
    
    get showNoVersionResults() {
        return this.versionSearch && this.filteredVersionCards.length === 0;
    }
    
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
    
    stripVersionClientSide(fullName, omniType) {
        if (!fullName) return '';
        
        if (omniType === 'DataMapper') {
            return fullName;
        }
        
        let result = fullName.trim();
        
        if (result.includes(' • ')) {
            const parts = result.split(' • ');
            if (parts.length >= 2) {
                let namePart = parts[0].trim();
                const typePart = parts.slice(1).join(' • ').trim();
                namePart = namePart.replace(/_\d+$/, '');
                result = namePart + ' • ' + typePart;
            }
        } else {
            result = result.replace(/_\d+$/, '');
        }
        
        result = result.replace(/\s+v\d+(\.\d+)?$/, '');
        
        return result;
    }
    
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
    
    onVersionSearchChange(e) {
        this.versionSearch = e.detail.value || '';
    }
    
    clearVersionSearch() {
        this.versionSearch = '';
    }
    
    switchToGridView() {
        this.versionViewMode = 'grid';
    }
    
    switchToListView() {
        this.versionViewMode = 'list';
    }
    
    async selectComponent(e) {
        this.selectedBaseName = e.currentTarget.dataset.basename;
        this.selectedType = e.currentTarget.dataset.type;
        this.selectedComponentName = this.selectedBaseName;
        
        this.selectedComponentId = null;
        this.selectedVersion = null;
        this.historyItems = [];
        this.versionCards = [];
        this.versionSearch = '';
        this.versionViewMode = 'grid';
        this.activeTab = 'summary';
        this.loadedSnapshotIds = new Set();
        this.lastUsedCursor = null;
        
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
        
        try {
            if (this.selectedType === 'DataMapper') {
                const drComp = this.componentList.find(c => 
                    c.fullName === this.selectedBaseName && c.type === 'DataMapper'
                );
                
                if (drComp) {
                    this.selectedComponentId = drComp.id;
                    this.selectedVersion = 1;
                    await this.loadHistory(true);
                }
                return;
            }
            
            const matchingComponents = this.componentList.filter(c => {
                const stripped = this.stripVersionClientSide(c.fullName, c.type);
                return stripped === this.selectedBaseName && c.type === this.selectedType;
            });
            
            if (matchingComponents.length === 0) {
                this.statusText = 'No versions found';
                return;
            }
            
            this.versionCards = matchingComponents.map(c => ({
                componentId: c.id,
                version: c.version || 1,
                label: `v${c.version || 1}`,
                fullName: c.fullName,
                latestAt: c.latestAt,
                latestActor: c.latestActor,
                formattedDate: c.latestAt ? this.formatDateTime(c.latestAt) : null
            }));
            
            this.versionCards.sort((a, b) => (b.version || 0) - (a.version || 0));
            
            this.statusText = 'Ready';
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
        this.activeTab = 'summary';
        await this.loadHistory(true);
    }
    
    async loadHistory(reset = false) {
        if (!this.selectedComponentId) return;
        if (this.tlLoading) return;
        
        const currentCursor = reset ? null : this.tlCursor;
        if (!reset && currentCursor === this.lastUsedCursor) {
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
            
            const incoming = (page.items || [])
                .filter(x => {
                    if (this.loadedSnapshotIds.has(x.id)) {
                        return false;
                    }
                    return true;
                })
                .map(x => {
                    this.loadedSnapshotIds.add(x.id);
                    return {
                        ...x,
                        showRawJson: false,
                        formattedDate: this.formatDateTime(x.at)
                    };
                });
            
            if (reset) {
                this.historyItems = [];
                this.loadedSnapshotIds = new Set();
                incoming.forEach(x => this.loadedSnapshotIds.add(x.id));
            }
            
            if (incoming.length > 0) {
                this.historyItems = [...this.historyItems, ...incoming];
                this.lastUsedCursor = currentCursor;
                this.tlCursor = page.nextCursor || null;
            } else if (page.nextCursor) {
                this.tlCursor = page.nextCursor;
                this.lastUsedCursor = currentCursor;
            } else {
                this.tlCursor = null;
            }
            
            this.statusText = 'Ready';
            
            setTimeout(() => {
                this.renderAiNotes();
                this.renderComparisonTables();
            }, 100);
        } catch(e) {
            console.error('loadHistory error:', e);
            this.statusText = 'Error loading history';
        } finally {
            this.tlLoading = false;
        }
    }
    
    renderAiNotes() {
        this.historyItems.forEach(snap => {
            const el = this.template.querySelector(`.notes-container[data-id="${snap.id}"]`);
            if (el && snap.aiNotesHtml && !el.dataset.rendered) {
                el.innerHTML = snap.aiNotesHtml;
                el.dataset.rendered = 'true';
            }
        });
    }
    
    // CRITICAL: Render two-column comparison table
    renderComparisonTables() {
        this.historyItems.forEach(snap => {
            const tableEl = this.template.querySelector(`[data-comparison-table-id="${snap.id}"]`);
            if (tableEl && snap.elementChangesSummary && !tableEl.dataset.rendered) {
                tableEl.innerHTML = this.buildComparisonTable(snap.elementChangesSummary);
                tableEl.dataset.rendered = 'true';
            }
        });
    }
    
    // Build two-column comparison table from ElementChangesSummary
    buildComparisonTable(elementSummary) {
        if (!elementSummary) return '<p class="muted">No element changes detected.</p>';
        
        const lines = elementSummary.split('\n');
        
        const prevElements = [];
        const currElements = [];
        
        let currentSection = '';
        
        for (let line of lines) {
            if (line.includes('=== ADDED')) {
                currentSection = 'ADDED';
            } else if (line.includes('=== REMOVED')) {
                currentSection = 'REMOVED';
            } else if (line.includes('=== MODIFIED')) {
                currentSection = 'MODIFIED';
            } else if (line.startsWith('+ ') && currentSection === 'ADDED') {
                const content = line.substring(2).trim();
                currElements.push({ content, status: 'added' });
            } else if (line.startsWith('- ') && currentSection === 'REMOVED') {
                const content = line.substring(2).trim();
                prevElements.push({ content, status: 'removed' });
            } else if (line.startsWith('~ ') && currentSection === 'MODIFIED') {
                const content = line.substring(2).trim();
                prevElements.push({ content, status: 'modified' });
                currElements.push({ content, status: 'modified' });
            } else if (line.trim().startsWith('Details:') || line.trim().startsWith('Changes:')) {
                // Append details to last element
                if (currentSection === 'ADDED' && currElements.length > 0) {
                    currElements[currElements.length - 1].details = line.trim();
                } else if (currentSection === 'REMOVED' && prevElements.length > 0) {
                    prevElements[prevElements.length - 1].details = line.trim();
                } else if (currentSection === 'MODIFIED' && currElements.length > 0) {
                    currElements[currElements.length - 1].details = line.trim();
                    if (prevElements.length > 0) {
                        prevElements[prevElements.length - 1].details = line.trim();
                    }
                }
            }
        }
        
        const maxRows = Math.max(prevElements.length, currElements.length);
        
        if (maxRows === 0) {
            return '<p class="muted">No element changes detected.</p>';
        }
        
        let html = '<table class="comparison-table">';
        html += '<thead><tr>';
        html += '<th class="comparison-header prev-header">Previous State</th>';
        html += '<th class="comparison-header curr-header">Current State</th>';
        html += '</tr></thead>';
        html += '<tbody>';
        
        for (let i = 0; i < maxRows; i++) {
            const prev = prevElements[i];
            const curr = currElements[i];
            
            html += '<tr class="comparison-row">';
            
            // Previous column
            if (prev) {
                let prevClass = 'comparison-cell prev-cell';
                let icon = '';
                
                if (prev.status === 'removed') {
                    prevClass += ' removed-cell';
                    icon = '✖ ';
                } else if (prev.status === 'modified') {
                    prevClass += ' modified-cell';
                    icon = '⟳ ';
                }
                
                html += `<td class="${prevClass}">${icon}${this.escapeHtml(prev.content)}`;
                if (prev.details) {
                    html += `<div class="cell-details">${this.escapeHtml(prev.details)}</div>`;
                }
                html += '</td>';
            } else {
                html += '<td class="comparison-cell prev-cell empty-cell"></td>';
            }
            
            // Current column
            if (curr) {
                let currClass = 'comparison-cell curr-cell';
                let icon = '';
                
                if (curr.status === 'added') {
                    currClass += ' added-cell';
                    icon = '+ ';
                } else if (curr.status === 'modified') {
                    currClass += ' modified-cell';
                    icon = '^ ';
                }
                
                html += `<td class="${currClass}">${icon}${this.escapeHtml(curr.content)}`;
                if (curr.details) {
                    html += `<div class="cell-details">${this.escapeHtml(curr.details)}</div>`;
                }
                html += '</td>';
            } else {
                html += '<td class="comparison-cell curr-cell empty-cell"></td>';
            }
            
            html += '</tr>';
        }
        
        html += '</tbody></table>';
        
        return html;
    }
    
    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
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
            this.loadHistory(false);
        }
    }
    
    switchTab(e) {
        this.activeTab = e.currentTarget.dataset.tab;
    }
    
    get showSummary() { return this.activeTab === 'summary'; }
    get showDiff() { return this.activeTab === 'diff'; }
    get showTimeline() { return this.activeTab === 'timeline'; }
    
    get summaryTabClass() { return this.activeTab === 'summary' ? 'active' : ''; }
    get diffTabClass() { return this.activeTab === 'diff' ? 'active' : ''; }
    get timelineTabClass() { return this.activeTab === 'timeline' ? 'active' : ''; }
    
    toggleRawJson(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.historyItems.find(x => x.id === id);
        if (item) {
            item.showRawJson = !item.showRawJson;
            this.historyItems = [...this.historyItems];
        }
    }
    
    copyDiff(e) {
        const id = e.currentTarget.dataset.id;
        const item = this.historyItems.find(x => x.id === id);
        if (item && item.diffText) {
            navigator.clipboard.writeText(item.diffText);
            this.showToast('Success', 'Diff copied to clipboard', 'success');
        }
    }
    
    showToast(title, message, variant) {
        const originalStatus = this.statusText;
        this.statusText = message;
        setTimeout(() => {
            this.statusText = originalStatus;
        }, 3000);
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
        this.versionSearch = '';
        this.versionViewMode = 'grid';
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