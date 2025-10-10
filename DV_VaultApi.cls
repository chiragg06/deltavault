public with sharing class DV_VaultApi {
    
    // DTOs
    public class CompPage { 
        @AuraEnabled public List<CompRow> items; 
        @AuraEnabled public String nextCursor; 
    }
    
    public class SnapPage { 
        @AuraEnabled public List<SnapRow> items; 
        @AuraEnabled public String nextCursor; 
    }
    
    public class CompRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String baseName;
        @AuraEnabled public String type;
        @AuraEnabled public String subType;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Datetime lastSeen;
        @AuraEnabled public Integer versionCount;
        @AuraEnabled public Decimal latestVersion;
        @AuraEnabled public String latestSource;
        @AuraEnabled public Datetime latestAt;
        @AuraEnabled public String latestAiSummary;
    }
    
    public class SnapRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Datetime at;
        @AuraEnabled public String changeType;
        @AuraEnabled public Decimal version;
        @AuraEnabled public String source;
        @AuraEnabled public String actorName;
        @AuraEnabled public String aiNotesHtml;
        @AuraEnabled public String diffText;
        @AuraEnabled public String rawJson;
        @AuraEnabled public Boolean open;
    }
    
    public class ContributorOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Integer count;
    }
    
    // Get list of contributors (users who have modified components)
    @AuraEnabled(cacheable=true)
    public static List<ContributorOption> getContributors(String family) {
        Set<String> allowed = new Set<String>{ 'OmniProcess', 'Flexcard', 'DataMapper' };
        
        String soql = 'SELECT ActorName__c actorName, COUNT(Id) cnt ' +
                      'FROM OmniSnapshot__c ';
        
        if (!String.isBlank(family) && family != 'all') {
            soql += 'WHERE OmniComponent__r.OmniType__c = :family ';
        } else {
            soql += 'WHERE OmniComponent__r.OmniType__c IN :allowed ';
        }
        
        soql += 'GROUP BY ActorName__c ' +
                'ORDER BY COUNT(Id) DESC ' +
                'LIMIT 200';
        
        List<ContributorOption> result = new List<ContributorOption>();
        
        // Add "All Contributors" option
        ContributorOption allOpt = new ContributorOption();
        allOpt.label = 'All Contributors';
        allOpt.value  = 'all';
        allOpt.count  = null;
        result.add(allOpt);
        
        for (AggregateResult ar : Database.query(soql)) {
            String actor = (String) ar.get('actorName');
            Integer cnt  = (Integer) ar.get('cnt');
            
            if (!String.isBlank(actor)) {
                ContributorOption opt = new ContributorOption();
                opt.label = actor + ' (' + cnt + ' changes)';
                opt.value = actor;
                opt.count = cnt;
                result.add(opt);
            }
        }
        
        return result;
    }
    
    // Get unified component list (deduplicated by BaseName)
    @AuraEnabled(cacheable=true)
    public static CompPage getComponentsPage(
        String family, 
        String contributor,
        String search, 
        Integer pageSize, 
        String cursor
    ) {
        if (pageSize == null || pageSize < 1) pageSize = 50;
        
        Datetime cTs = null; 
        Id cId = null;
        
        if (!String.isBlank(cursor) && cursor.contains('|')) {
            List<String> p = cursor.split('\\|'); 
            Long ms = Long.valueOf(p[0]);
            Datetime epoch = Datetime.newInstance(1970,1,1,0,0,0);
            cTs = epoch.addSeconds((Integer)(ms/1000)); 
            cId = Id.valueOf(p[1]);
        }
        
        Set<String> allowed = new Set<String>{ 'OmniProcess', 'Flexcard', 'DataMapper' };
        
        // Query components with BaseName grouping
        String soql = 'SELECT Id, Name, FullName__c, BaseName__c, OmniType__c, SubType__c, ' +
                      'IsActive__c, LastSeenModified__c ' +
                      'FROM OmniComponent__c ' +
                      'WHERE OmniType__c IN :allowed ';
        
        if (!String.isBlank(family) && family != 'all') {
            soql += 'AND OmniType__c = :family ';
        }
        
        if (!String.isBlank(search)) {
            String likel = '%' + search + '%';
            soql += 'AND BaseName__c LIKE :likel ';
        }
        
        if (cTs != null && cId != null) {
            soql += 'AND (LastSeenModified__c < :cTs OR (LastSeenModified__c = :cTs AND Id < :cId)) ';
        }
        
        soql += 'ORDER BY LastSeenModified__c DESC, Id DESC LIMIT :pageSize';
        
        List<OmniComponent__c> rows = Database.query(soql);
        
        // Get snapshot data with contributor filter
        Set<Id> compIds = new Set<Id>();
        for (OmniComponent__c e : rows) compIds.add(e.Id);
        
        Map<String, SnapInfo> baseNameToLatest = new Map<String, SnapInfo>();
        Map<String, Integer> baseNameToCount  = new Map<String, Integer>();
        
        if (!compIds.isEmpty()) {
            String snapSoql = 'SELECT Id, OmniComponent__c, OmniComponent__r.BaseName__c, ' +
                              'Version__c, ModifiedAt__c, Source__c, ActorName__c, AI_Notes_Markdown__c ' +
                              'FROM OmniSnapshot__c ' +
                              'WHERE OmniComponent__c IN :compIds ';
            
            if (!String.isBlank(contributor) && contributor != 'all') {
                snapSoql += 'AND ActorName__c = :contributor ';
            }
            
            snapSoql += 'ORDER BY ModifiedAt__c DESC, Id DESC';
            
            for (OmniSnapshot__c s : Database.query(snapSoql)) {
                String base = s.OmniComponent__r.BaseName__c;
                
                // Count versions per base
                if (!baseNameToCount.containsKey(base)) {
                    baseNameToCount.put(base, 0);
                }
                baseNameToCount.put(base, baseNameToCount.get(base) + 1);
                
                // Track latest per base
                if (!baseNameToLatest.containsKey(base)) {
                    baseNameToLatest.put(
                        base,
                        new SnapInfo(
                            s.Version__c, 
                            s.ModifiedAt__c, 
                            s.Source__c,
                            s.ActorName__c,
                            s.AI_Notes_Markdown__c
                        )
                    );
                }
            }
        }
        
        // Deduplicate by BaseName
        Map<String, CompRow> baseNameToRow = new Map<String, CompRow>();
        
        for (OmniComponent__c e : rows) {
            String base = String.isNotBlank(e.BaseName__c) ? e.BaseName__c : DV_Util.stripVersion(e.FullName__c);
            
            if (!baseNameToRow.containsKey(base)) {
                CompRow r = new CompRow();
                r.id = e.Id;
                r.name = String.isNotBlank(e.FullName__c) ? e.FullName__c : e.Name;
                r.baseName = base;
                r.type = e.OmniType__c;
                r.subType = e.SubType__c;
                r.active = e.IsActive__c;
                r.lastSeen = e.LastSeenModified__c;
                r.versionCount = baseNameToCount.containsKey(base) ? baseNameToCount.get(base) : 0;
                
                SnapInfo latest = baseNameToLatest.get(base);
                if (latest != null) {
                    r.latestVersion = latest.version;
                    r.latestSource  = latest.source;
                    r.latestAt      = latest.modifiedAt;
                    r.latestAiSummary = extractSummary(latest.aiNotes);
                }
                
                baseNameToRow.put(base, r);
            }
        }
        
        CompPage page = new CompPage();
        page.items = baseNameToRow.values();
        
        if (!rows.isEmpty()) {
            OmniComponent__c tail = rows[rows.size()-1];
            Long ms = tail.LastSeenModified__c == null ? 0 : tail.LastSeenModified__c.getTime();
            page.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        
        return page;
    }
    
    // Get all versions for a specific BaseName
    @AuraEnabled(cacheable=true)
    public static List<Decimal> getVersionsForBase(String baseName, String omniType) {
        if (String.isBlank(baseName) || String.isBlank(omniType)) return new List<Decimal>();
        
        List<Decimal> out = new List<Decimal>();
        
        for (AggregateResult ar : [
            SELECT Version__c v
            FROM OmniSnapshot__c
            WHERE BaseName__c = :baseName
            AND OmniComponent__r.OmniType__c = :omniType
            AND Version__c != NULL
            GROUP BY Version__c
            ORDER BY Version__c DESC
        ]) {
            out.add((Decimal) ar.get('v'));
        }
        
        return out;
    }
    
    // Get timeline for a specific version
    @AuraEnabled(cacheable=true)
    public static SnapPage getSnapshotsForVersion(
        String baseName, 
        String omniType, 
        Decimal version,
        String contributor,
        Integer pageSize, 
        String cursor
    ) {
        if (pageSize == null || pageSize < 1) pageSize = 30;
        
        SnapPage page = new SnapPage();
        page.items = new List<SnapRow>();
        page.nextCursor = null;
        
        if (String.isBlank(baseName) || String.isBlank(omniType) || version == null) return page;
        
        Datetime cTs = null; 
        Id cId = null;
        
        if (!String.isBlank(cursor) && cursor.contains('|')) {
            List<String> p = cursor.split('\\|'); 
            Long ms = Long.valueOf(p[0]);
            Datetime epoch = Datetime.newInstance(1970,1,1,0,0,0);
            cTs = epoch.addSeconds((Integer)(ms/1000)); 
            cId = Id.valueOf(p[1]);
        }
        
        String wherel = ' WHERE BaseName__c = :baseName ' +
                        ' AND Version__c = :version ' +
                        ' AND OmniComponent__r.OmniType__c = :omniType ';
        
        if (!String.isBlank(contributor) && contributor != 'all') {
            wherel += ' AND ActorName__c = :contributor ';
        }
        
        if (cTs != null && cId != null) {
            wherel += ' AND (ModifiedAt__c < :cTs OR (ModifiedAt__c = :cTs AND Id < :cId)) ';
        }
        
        List<OmniSnapshot__c> snaps = Database.query(
            'SELECT Id, ModifiedAt__c, ChangeType__c, Version__c, Source__c, ActorName__c, ' +
            'AI_Notes_Markdown__c, DiffToPrev__c, RawJSON__c ' +
            'FROM OmniSnapshot__c ' + wherel +
            'ORDER BY ModifiedAt__c DESC, Id DESC LIMIT :pageSize'
        );
        
        for (OmniSnapshot__c s : snaps) {
            SnapRow r = new SnapRow();
            r.id = s.Id;
            r.at = s.ModifiedAt__c;
            r.changeType = s.ChangeType__c;
            r.version = s.Version__c;
            r.source = s.Source__c;
            r.actorName = s.ActorName__c;
            r.aiNotesHtml = s.AI_Notes_Markdown__c;
            r.diffText = s.DiffToPrev__c;
            r.rawJson = s.RawJSON__c;
            r.open = false;
            
            page.items.add(r);
        }
        
        if (!snaps.isEmpty()) {
            OmniSnapshot__c tail = snaps[snaps.size()-1];
            Long ms = tail.ModifiedAt__c == null ? 0 : tail.ModifiedAt__c.getTime();
            page.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        
        return page;
    }
    
    // Helper class for snapshot info
    private class SnapInfo {
        Decimal version;
        Datetime modifiedAt;
        String source;
        String actorName;
        String aiNotes;
        
        SnapInfo(Decimal v, Datetime d, String s, String a, String n) {
            this.version = v;
            this.modifiedAt = d;
            this.source = s;
            this.actorName = a;
            this.aiNotes = n;
        }
    }
    
    // Extract summary from AI notes HTML
    private static String extractSummary(String html) {
        if (String.isBlank(html)) return '';
        
        // Remove HTML tags and get first 100 chars
        String text = html.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
        
        if (text.length() > 100) {
            return text.substring(0, 100) + '...';
        }
        
        return text;
    }
}
