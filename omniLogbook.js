import { LightningElement, track } from 'lwc';
import getRecent from '@salesforce/apex/OmniLogbookController.getRecent';
import getComponentDetails from '@salesforce/apex/OmniLogbookController.getComponentDetails';

// ⬇️ use discovery-based listing so it works with vlocity_cmt__OmniScript__c
import listOmniScripts from '@salesforce/apex/OmniLogbookDiscovery.listOmniScripts';

// keep your existing actions
import trackAndIngest from '@salesforce/apex/OmniLogbookActions.trackAndIngest';
import trackOmniScripts from '@salesforce/apex/OmniLogbookAdmin.trackOmniScripts';

export default class OmniLogbook extends LightningElement {
  // left pane
  @track recentItems;
  @track selectedId;

  // details
  @track details = { aiNotesMarkdown: '', diffUnified: '', rawText: '', timeline: [] };
  @track title = 'Welcome';

  // UI state
  @track statusText = 'Ready';
  @track activeTab = 'notes';

  // manage modal
  @track showManage = false;
  @track available = [];
  @track search = '';
  @track filterMode = 'all'; // 'all' | 'tracked' | 'untracked'
  selected = new Set();

  // formatted timeline rows
  @track timelineRows = [];

  // tabs
  get showNotes(){ return this.activeTab === 'notes'; }
  get showDiff(){ return this.activeTab === 'diff'; }
  get showRaw(){ return this.activeTab === 'raw'; }
  get showTimeline(){ return this.activeTab === 'timeline'; }
  get notesTabClass(){ return this.activeTab === 'notes' ? 'active' : ''; }
  get diffTabClass(){ return this.activeTab === 'diff' ? 'active' : ''; }
  get rawTabClass(){ return this.activeTab === 'raw' ? 'active' : ''; }
  get timelineTabClass(){ return this.activeTab === 'timeline' ? 'active' : ''; }

  connectedCallback(){ this.loadRecent(); }

  // Load recent components
  async loadRecent(){
    this.statusText = 'Loading…';
    try {
      const res = await getRecent({ limitSize: 25 });
      this.recentItems = res;
      if (res && res.length){
        this.selectedId = res[0].id;
        this.title = `${res[0].type}: ${res[0].name}`;
        await this.loadDetails(res[0].id);
      }
      this.statusText = 'Ready';
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error(e);
      this.statusText = 'Error loading recent';
    }
  }

  // Load details for selected component
  async loadDetails(id){
    try {
      const d = await getComponentDetails({ componentId: id });
      this.details = d || { aiNotesMarkdown:'', diffUnified:'', rawText:'', timeline:[] };

      // Defer DOM writes to ensure elements exist
      requestAnimationFrame(() => {
        // NOTES (HTML)
        const mdEl = this.template.querySelector('.markdown');
        if (mdEl) mdEl.innerHTML = this.details.aiNotesMarkdown || '<p class="muted">No AI notes yet.</p>';

        // DIFF (HTML)
        const diffEl = this.template.querySelector('.diff');
        if (diffEl) diffEl.innerHTML = this.renderDiffHtml(this.details.diffUnified || '');
      });

      // TIMELINE (format timestamps)
      this.timelineRows = (this.details.timeline || []).map(t => ({
        key: `${t.version}-${t.at}`,
        version: t.version,
        when: this.fmtDateTime(t.at),
        actor: t.actor
      }));
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error(e);
      this.statusText = 'Error loading details';
    }
  }

  // Diff: simple HTML with +/– styling
  renderDiffHtml(txt){
    const esc = s => (s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    const lines = (txt || '').split('\n');
    const out = ['<pre class="block diff-pre">'];
    for (let line of lines) {
      if (line.startsWith('+ ')) out.push('<div class="d add">+' + esc(line.slice(2)) + '</div>');
      else if (line.startsWith('- ')) out.push('<div class="d del">-' + esc(line.slice(2)) + '</div>');
      else if (line.startsWith('---') || line.startsWith('+++')) out.push('<div class="d hdr">' + esc(line) + '</div>');
      else out.push('<div class="d ctx">' + esc(line) + '</div>');
    }
    out.push('</pre>');
    return out.join('');
  }

  // Friendly date/time
  fmtDateTime(dt){
    try {
      const d = new Date(dt);
      return d.toLocaleString(undefined, {
        year: 'numeric', month: 'short', day: '2-digit',
        hour: '2-digit', minute: '2-digit'
      });
    } catch (e) {
      return dt;
    }
  }

  // UI handlers
  async select(evt){
    const id = evt.currentTarget.dataset.id;
    this.selectedId = id;
    const item = (this.recentItems || []).find(x => x.id === id);
    this.title = item ? `${item.type}: ${item.name}` : 'Details';
    await this.loadDetails(id);
  }
  switchTab(evt){ this.activeTab = evt.currentTarget.dataset.tab; }
  async refresh(){ await this.loadRecent(); }

  // Manage modal
  async openManage(){
    this.selected = new Set();
    this.search = '';
    this.filterMode = 'all';
    this.showManage = true;
    await this.loadAvailable();
  }
  closeManage(){ this.showManage = false; }
  async onSearch(evt){ this.search = evt.target.value || ''; await this.loadAvailable(); }
  // optional chip/toggle handler in your template can call this:
  async setFilterMode(mode){ this.filterMode = mode || 'all'; await this.loadAvailable(); }

  async loadAvailable(){
    try {
      const list = await listOmniScripts({
        search: this.search,
        limitSize: 200,
        onlyFilter: this.filterMode // 'all' | 'tracked' | 'untracked'
      });

      // map rows; keep selection state; include tracked/expiry for display if your template shows it
      this.available = (list || []).map(x => ({
        ...x,
        checked: this.selected.has(x.id),
        right: x.tracked
          ? (x.expiresAt ? `Tracked • until ${new Date(x.expiresAt).toLocaleString()}` : 'Tracked')
          : 'Not tracked'
      }));
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error(e);
      this.available = [];
    }
  }

  toggle(evt){
    const id = evt.target.value;
    const checked = evt.target.checked;
    if (checked) this.selected.add(id);
    else this.selected.delete(id);

    const idx = this.available.findIndex(r => r.id === id);
    if (idx > -1) {
      const copy = [...this.available];
      copy[idx] = { ...copy[idx], checked };
      this.available = copy;
    }
  }

  async saveManage(){
    try {
      if (this.selected.size === 0) { this.closeManage(); return; }
      const ids = Array.from(this.selected.values());

      // 1) stamp/renew 2-week window
      await trackOmniScripts({ omniScriptIds: ids });

      // 2) immediate ingest (so snapshots appear now)
      this.statusText = 'Ingesting…';
      const jobId = await trackAndIngest({ omniScriptIds: ids });

      this.closeManage();
      window.setTimeout(() => this.loadRecent(), 3000);
      this.statusText = 'Queued: ' + jobId;
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error(e);
      this.statusText = 'Error queuing ingest';
    }
  }
}
