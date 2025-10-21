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
        @AuraEnabled public String fullName;
        @AuraEnabled public String type;
        @AuraEnabled public String subType;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Datetime lastSeen;
        @AuraEnabled public Decimal version;
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
        @AuraEnabled public String elementChangesSummary;
        @AuraEnabled public String elementsArray; // NEW: Clean element data
    }
    
    public class ContributorOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Integer count;
    }
    
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

        Datetime cTs = null;
        Id cId = null;
        if (!String.isBlank(cursor) && cursor.contains('|')) {
            List<String> p = cursor.split('\\|');
            Long ms = Long.valueOf(p[0]);
            cTs = Datetime.newInstance(1970,1,1).addSeconds((Integer)(ms/1000));
            cId = Id.valueOf(p[1]);
        }

        String whereClause = ' WHERE OmniType__c IN :allowed AND FullName__c != null ';
        
        if (!String.isBlank(family) && family != 'all') {
            whereClause += ' AND OmniType__c = :family ';
        }
        
        if (!String.isBlank(search)) {
            String likel = '%' + search + '%';
            whereClause += ' AND FullName__c LIKE :likel ';
        }
        
        if (cTs != null && cId != null) {
            whereClause += ' AND (LastSeenModified__c < :cTs OR (LastSeenModified__c = :cTs AND Id < :cId)) ';
        }

        List<OmniComponent__c> comps = Database.query(
            'SELECT Id, FullName__c, OmniType__c, SubType__c, IsActive__c, LastSeenModified__c ' +
            'FROM OmniComponent__c ' + whereClause +
            'ORDER BY LastSeenModified__c DESC, Id DESC ' +
            'LIMIT :pageSize'
        );

        List<CompRow> items = new List<CompRow>();
        Set<Id> compIds = new Set<Id>();
        for (OmniComponent__c c : comps) {
            compIds.add(c.Id);
        }

        Map<Id, OmniSnapshot__c> latestSnapByComp = new Map<Id, OmniSnapshot__c>();
        if (!compIds.isEmpty()) {
            for (OmniSnapshot__c s : [
                SELECT Id, OmniComponent__c, Version__c, ModifiedAt__c, ChangeType__c, ActorName__c
                FROM OmniSnapshot__c
                WHERE OmniComponent__c IN :compIds
                ORDER BY ModifiedAt__c DESC, Id DESC
            ]) {
                if (!latestSnapByComp.containsKey(s.OmniComponent__c)) {
                    latestSnapByComp.put(s.OmniComponent__c, s);
                }
            }
        }

        for (OmniComponent__c c : comps) {
            CompRow row = new CompRow();
            row.id = c.Id;
            row.fullName = c.FullName__c;
            row.type = c.OmniType__c;
            row.subType = c.SubType__c;
            row.active = c.IsActive__c;
            row.lastSeen = c.LastSeenModified__c;

            OmniSnapshot__c snap = latestSnapByComp.get(c.Id);
            if (snap != null) {
                row.version = snap.Version__c;
                row.latestAt = snap.ModifiedAt__c;
                row.latestChangeType = snap.ChangeType__c;
                row.latestActor = snap.ActorName__c;
            }

            items.add(row);
        }

        CompPage page = new CompPage();
        page.items = items;
        page.totalCount = items.size();
        
        if (!comps.isEmpty()) {
            OmniComponent__c tail = comps[comps.size()-1];
            Long ms = tail.LastSeenModified__c == null ? 0 : tail.LastSeenModified__c.getTime();
            page.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        
        return page;
    }
    
    @AuraEnabled(cacheable=true)
    public static SnapPage getSnapshotsForComponent(
        Id componentId,
        String contributor,
        Integer pageSize, 
        String cursor
    ) {
        if (pageSize == null || pageSize < 1) pageSize = 30;
        
        SnapPage page = new SnapPage();
        page.items = new List<SnapRow>();
        
        if (componentId == null) {
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
        
        String whereClause = ' WHERE OmniComponent__c = :componentId ';
        
        if (!String.isBlank(contributor) && contributor != 'all') {
            whereClause += ' AND ActorName__c = :contributor ';
        }
        
        if (cTs != null && cId != null) {
            whereClause += ' AND (ModifiedAt__c < :cTs OR (ModifiedAt__c = :cTs AND Id < :cId)) ';
        }
        
        // CRITICAL: Include ElementsArray__c for clean element data
        List<OmniSnapshot__c> snaps = Database.query(
            'SELECT Id, ModifiedAt__c, ChangeType__c, Version__c, Source__c, ActorName__c, ' +
            'AI_Notes_Markdown__c, DiffToPrev__c, RawJSON__c, ElementChangesSummary__c, ElementsArray__c ' +
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
            r.elementChangesSummary = s.ElementChangesSummary__c;
            r.elementsArray = s.ElementsArray__c; // NEW: Clean element data
            
            page.items.add(r);
        }
        
        if (!snaps.isEmpty()) {
            OmniSnapshot__c tail = snaps[snaps.size()-1];
            Long ms = tail.ModifiedAt__c == null ? 0 : tail.ModifiedAt__c.getTime();
            page.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        
        return page;
    }
    
    // CRITICAL: Helper method to compare element arrays for diff table
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getElementComparison(Id currentSnapshotId, Id previousSnapshotId) {
        List<OmniSnapshot__c> snaps = [
            SELECT Id, ElementsArray__c, Source__c
            FROM OmniSnapshot__c
            WHERE Id IN :new List<Id>{currentSnapshotId, previousSnapshotId}
        ];
        
        if (snaps.size() < 2) {
            return new Map<String, Object>{
                'error' => 'Not enough snapshots to compare'
            };
        }
        
        OmniSnapshot__c current = snaps[0];
        OmniSnapshot__c previous = snaps[1];
        
        List<Map<String, Object>> diffRows = new List<Map<String, Object>>();
        
        if (String.isNotBlank(current.ElementsArray__c) && String.isNotBlank(previous.ElementsArray__c)) {
            List<Object> currElements = (List<Object>) JSON.deserializeUntyped(current.ElementsArray__c);
            List<Object> prevElements = (List<Object>) JSON.deserializeUntyped(previous.ElementsArray__c);
            
            Map<String, Map<String, Object>> prevMap = new Map<String, Map<String, Object>>();
            Map<String, Map<String, Object>> currMap = new Map<String, Map<String, Object>>();
            
            for (Object obj : prevElements) {
                Map<String, Object> elem = (Map<String, Object>) obj;
                String name = (String) elem.get('Name');
                prevMap.put(name, elem);
            }
            
            for (Object obj : currElements) {
                Map<String, Object> elem = (Map<String, Object>) obj;
                String name = (String) elem.get('Name');
                currMap.put(name, elem);
            }
            
            Set<String> allNames = new Set<String>();
            allNames.addAll(prevMap.keySet());
            allNames.addAll(currMap.keySet());
            
            for (String name : allNames) {
                Map<String, Object> prevElem = prevMap.get(name);
                Map<String, Object> currElem = currMap.get(name);
                
                Map<String, Object> row = new Map<String, Object>();
                row.put('name', name);
                
                if (prevElem == null && currElem != null) {
                    // Added
                    row.put('status', 'added');
                    row.put('previous', '');
                    row.put('current', formatElement(currElem));
                } else if (prevElem != null && currElem == null) {
                    // Removed
                    row.put('status', 'removed');
                    row.put('previous', formatElement(prevElem));
                    row.put('current', '');
                } else if (JSON.serialize(prevElem) != JSON.serialize(currElem)) {
                    // Modified
                    row.put('status', 'modified');
                    row.put('previous', formatElement(prevElem));
                    row.put('current', formatElement(currElem));
                } else {
                    // Unchanged
                    row.put('status', 'unchanged');
                    row.put('previous', formatElement(prevElem));
                    row.put('current', formatElement(currElem));
                }
                
                diffRows.add(row);
            }
        }
        
        return new Map<String, Object>{
            'diffRows' => diffRows,
            'source' => current.Source__c
        };
    }
    
    private static String formatElement(Map<String, Object> elem) {
        if (elem == null) return '';
        
        String name = (String) elem.get('Name');
        String type = (String) elem.get('Type');
        
        String result = name + ' (' + type + ')';
        
        if (elem.containsKey('Level')) {
            result += ' [Level: ' + elem.get('Level') + ']';
        }
        
        if (elem.containsKey('InputFieldName')) {
            result += ' [In: ' + elem.get('InputFieldName') + ']';
        }
        
        if (elem.containsKey('OutputFieldName')) {
            result += ' [Out: ' + elem.get('OutputFieldName') + ']';
        }
        
        return result;
    }
}