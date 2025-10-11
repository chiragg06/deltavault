public with sharing class DV_VaultApi {
    
    public class CompPage { 
        @AuraEnabled public List<CompRow> items; 
        @AuraEnabled public String nextCursor; 
        @AuraEnabled public Integer totalCount;
    }
    
    public class SnapPage { 
        @AuraEnabled public List<SnapRow> items; 
        @AuraEnabled public String nextCursor; 
    }
    
    public class CompRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String baseName;
        @AuraEnabled public String type;
        @AuraEnabled public String subType;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Datetime lastSeen;
        @AuraEnabled public Integer versionCount;
        @AuraEnabled public Decimal latestVersion;
        @AuraEnabled public Datetime latestAt;
        @AuraEnabled public String latestChangeType;
        @AuraEnabled public String latestActor;
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
    }
    
    public class ContributorOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Integer count;
    }
    
    // Get contributors (unchanged)
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
        
        soql += 'GROUP BY ActorName__c ORDER BY COUNT(Id) DESC LIMIT 200';
        
        List<ContributorOption> result = new List<ContributorOption>();
        ContributorOption allOpt = new ContributorOption();
        allOpt.label = 'All Contributors';
        allOpt.value = 'all';
        result.add(allOpt);
        
        for (AggregateResult ar : Database.query(soql)) {
            String actor = (String) ar.get('actorName');
            Integer cnt = (Integer) ar.get('cnt');
            
            if (!String.isBlank(actor)) {
                ContributorOption opt = new ContributorOption();
                opt.label = actor + ' (' + cnt + ')';
                opt.value = actor;
                opt.count = cnt;
                result.add(opt);
            }
        }
        
        return result;
    }
    
    // IMPROVED: Get unique components grouped by BaseName
    @AuraEnabled(cacheable=true)
public static CompPage getComponentsPage(
    String family, 
    String contributor,
    String search, 
    Integer pageSize, 
    String cursor
) {
    if (pageSize == null || pageSize < 1) pageSize = 50;

    Set<String> allowed = new Set<String>{ 'OmniProcess', 'Flexcard', 'DataMapper' };

    // Step 1: Get unique BaseNames (latest-seen ordering)
    String baseQuery = 'SELECT BaseName__c, OmniType__c, MAX(LastSeenModified__c) maxSeen ' +
                       'FROM OmniComponent__c ' +
                       'WHERE OmniType__c IN :allowed AND BaseName__c != null ';
    if (!String.isBlank(family) && family != 'all') {
        baseQuery += 'AND OmniType__c = :family ';
    }
    if (!String.isBlank(search)) {
        String likel = '%' + search + '%';
        baseQuery += 'AND BaseName__c LIKE :likel ';
    }
    baseQuery += 'GROUP BY BaseName__c, OmniType__c ' +
                 'ORDER BY MAX(LastSeenModified__c) DESC ' +
                 'LIMIT 1000';

    List<AggregateResult> baseResults = Database.query(baseQuery);

    // Step 2: Build component rows with aggregated data
    List<CompRow> items = new List<CompRow>();

    for (AggregateResult ar : baseResults) {
        String baseName = (String) ar.get('BaseName__c');
        String omniType = (String) ar.get('OmniType__c');
        Datetime maxSeen = (Datetime) ar.get('maxSeen');

        // Latest snapshot for this base/type
        List<OmniSnapshot__c> snaps = [
            SELECT Id, Version__c, ModifiedAt__c, ChangeType__c, ActorName__c
            FROM OmniSnapshot__c
            WHERE BaseName__c = :baseName
            AND OmniComponent__r.OmniType__c = :omniType
            ORDER BY Version__c DESC, ModifiedAt__c DESC
            LIMIT 1
        ];

        // Count total versions (distinct)
        Integer versionCount = 0;
        AggregateResult[] cntAr = [
            SELECT COUNT_DISTINCT(Version__c) vcount
            FROM OmniSnapshot__c
            WHERE BaseName__c = :baseName
            AND OmniComponent__r.OmniType__c = :omniType
        ];
        if (!cntAr.isEmpty()) {
            Object v = cntAr[0].get('vcount');
            if (v instanceof Integer) {
                versionCount = (Integer)v;
            } else if (v instanceof Long) {
                versionCount = (Integer)((Long)v);
            }
        }

        // One representative component row (for subtype/active/id)
        List<OmniComponent__c> comps = [
            SELECT Id, SubType__c, IsActive__c
            FROM OmniComponent__c
            WHERE BaseName__c = :baseName
            AND OmniType__c = :omniType
            LIMIT 1
        ];

        CompRow row = new CompRow();
        row.baseName = baseName;
        row.type = omniType;
        row.lastSeen = maxSeen;
        row.versionCount = versionCount;

        if (!comps.isEmpty()) {
            row.id = comps[0].Id;
            row.subType = comps[0].SubType__c;
            row.active = comps[0].IsActive__c;
        }

        if (!snaps.isEmpty()) {
            row.latestVersion = snaps[0].Version__c;
            row.latestAt = snaps[0].ModifiedAt__c;
            row.latestChangeType = snaps[0].ChangeType__c;
            row.latestActor = snaps[0].ActorName__c;
        }

        items.add(row);
    }

    CompPage page = new CompPage();
    page.items = items;
    page.totalCount = items.size();
    // Optional: compute nextCursor if you later add true pagination on baseQuery
    return page;
}

    
    // Get versions for a specific BaseName
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
    
    // Get timeline for specific version with contributor filter
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
        
        if (String.isBlank(baseName) || String.isBlank(omniType) || version == null) {
            return page;
        }
        
        Datetime cTs = null; 
        Id cId = null;
        
        if (!String.isBlank(cursor) && cursor.contains('|')) {
            List<String> p = cursor.split('\\|'); 
            Long ms = Long.valueOf(p[0]);
            cTs = Datetime.newInstance(1970,1,1).addSeconds((Integer)(ms/1000)); 
            cId = Id.valueOf(p[1]);
        }
        
        String whereClause = ' WHERE BaseName__c = :baseName ' +
                           ' AND Version__c = :version ' +
                           ' AND OmniComponent__r.OmniType__c = :omniType ';
        
        if (!String.isBlank(contributor) && contributor != 'all') {
            whereClause += ' AND ActorName__c = :contributor ';
        }
        
        if (cTs != null && cId != null) {
            whereClause += ' AND (ModifiedAt__c < :cTs OR (ModifiedAt__c = :cTs AND Id < :cId)) ';
        }
        
        List<OmniSnapshot__c> snaps = Database.query(
            'SELECT Id, ModifiedAt__c, ChangeType__c, Version__c, Source__c, ActorName__c, ' +
            'AI_Notes_Markdown__c, DiffToPrev__c, RawJSON__c ' +
            'FROM OmniSnapshot__c ' + whereClause +
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
            
            page.items.add(r);
        }
        
        if (!snaps.isEmpty()) {
            OmniSnapshot__c tail = snaps[snaps.size()-1];
            Long ms = tail.ModifiedAt__c == null ? 0 : tail.ModifiedAt__c.getTime();
            page.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        
        return page;
    }
}