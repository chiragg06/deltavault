public with sharing class DV_LogbookController {

    // ---------- DTOs ----------
    public class CompRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String subType;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Boolean tracked;
        @AuraEnabled public Datetime lastSeen;
        @AuraEnabled public Decimal latestVersion;
        @AuraEnabled public String  latestSource;
        @AuraEnabled public Datetime latestAt;
    }
    public class CompPage {
        @AuraEnabled public List<CompRow> items;
        @AuraEnabled public String nextCursor;
    }

    public class SnapRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Datetime whenn;
        @AuraEnabled public String changeType;
        @AuraEnabled public Decimal version;
        @AuraEnabled public String source;
        @AuraEnabled public String notesHtml;
        @AuraEnabled public String diff;
        @AuraEnabled public String rawJson;
    }
    public class SnapPage {
        @AuraEnabled public List<SnapRow> items;
        @AuraEnabled public String nextCursor;
    }

    // ---------- Components pager ----------
    @AuraEnabled(cacheable=true)
    public static CompPage listComponentsPage(String typeFilter, String subTypeFilter, Integer pageSize, String cursor, String search) {
        if (pageSize == null || pageSize < 1) pageSize = 20;

        Datetime cTs = null; Id cId = null;
        if (!String.isBlank(cursor) && cursor.contains('|')) {
            List<String> p = cursor.split('\\|');
            Long ms = Long.valueOf(p[0]);
            Datetime epoch = Datetime.newInstance(1970,1,1,0,0,0);
            cTs = epoch.addSeconds((Integer)(ms/1000));
            cId = Id.valueOf(p[1]);
        }

        String soql = 'SELECT Id, Name, FullName__c, OmniType__c, SubType__c, IsActive__c, Tracked__c, LastSeenModified__c ' +
                      'FROM OmniComponent__c ';
        List<String> wh = new List<String>();
        if (!String.isBlank(typeFilter))    wh.add('OmniType__c = :typeFilter');
        if (!String.isBlank(subTypeFilter)) wh.add('SubType__c = :subTypeFilter');
        if (!String.isBlank(search)) {
            String likel = '%' + search + '%';
            wh.add('FullName__c LIKE :like');
        }
        if (cTs != null && cId != null) {
            wh.add('(LastSeenModified__c < :cTs OR (LastSeenModified__c = :cTs AND Id < :cId))');
        }
        if (!wh.isEmpty()) soql += 'WHERE ' + String.join(wh, ' AND ') + ' ';
        soql += 'ORDER BY LastSeenModified__c DESC, Id DESC LIMIT :pageSize';

        List<OmniComponent__c> rows = Database.query(soql);

        // last snapshot per component
        Map<Id, OmniSnapshot__c> lastBy = new Map<Id, OmniSnapshot__c>();
        if (!rows.isEmpty()) {
            for (OmniSnapshot__c s : [
                SELECT Id, OmniComponent__c, Version__c, ModifiedAt__c, Source__c
                FROM OmniSnapshot__c
                WHERE OmniComponent__c IN :rows
                ORDER BY ModifiedAt__c DESC, Id DESC
            ]) {
                if (!lastBy.containsKey(s.OmniComponent__c)) lastBy.put(s.OmniComponent__c, s);
            }
        }

        CompPage out = new CompPage();
        out.items = new List<CompRow>();
        for (OmniComponent__c e : rows) {
            CompRow r = new CompRow();
            r.id = e.Id;
            r.name = String.isNotBlank(e.FullName__c) ? e.FullName__c : e.Name;
            r.type = e.OmniType__c;
            r.subType = e.SubType__c;
            r.active = e.IsActive__c;
            r.tracked = e.Tracked__c;
            r.lastSeen = e.LastSeenModified__c;

            OmniSnapshot__c last = lastBy.get(e.Id);
            if (last != null) {
                r.latestVersion = last.Version__c;
                r.latestSource  = last.Source__c;
                r.latestAt      = last.ModifiedAt__c;
            }
            out.items.add(r);
        }

        if (!rows.isEmpty()) {
            OmniComponent__c tail = rows[rows.size()-1];
            Long ms = tail.LastSeenModified__c==null ? 0 : tail.LastSeenModified__c.getTime();
            out.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        return out;
    }

    // ---------- Snapshots pager ----------
    @AuraEnabled(cacheable=true)
    public static SnapPage getSnapshotsPage(Id componentId, Integer pageSize, String cursor) {
        if (pageSize == null || pageSize < 1) pageSize = 20;

        Datetime cTs = null; Id cId = null;
        if (!String.isBlank(cursor) && cursor.contains('|')) {
            List<String> p = cursor.split('\\|');
            Long ms = Long.valueOf(p[0]);
            Datetime epoch = Datetime.newInstance(1970,1,1,0,0,0);
            cTs = epoch.addSeconds((Integer)(ms/1000));
            cId = Id.valueOf(p[1]);
        }

        String wh = ' WHERE OmniComponent__c = :componentId ';
        if (cTs != null && cId != null)
            wh += ' AND (ModifiedAt__c < :cTs OR (ModifiedAt__c = :cTs AND Id < :cId)) ';

        List<OmniSnapshot__c> snaps = Database.query(
            'SELECT Id, ModifiedAt__c, ChangeType__c, Version__c, Source__c, AI_Notes_Markdown__c, DiffToPrev__c, RawJSON__c ' +
            'FROM OmniSnapshot__c ' + wh +
            'ORDER BY ModifiedAt__c DESC, Id DESC LIMIT :pageSize'
        );

        SnapPage page = new SnapPage();
        page.items = new List<SnapRow>();
        for (OmniSnapshot__c s : snaps) {
            SnapRow r = new SnapRow();
            r.id = s.Id;
            r.whenn = s.ModifiedAt__c;
            r.changeType = s.ChangeType__c;
            r.version = s.Version__c;
            r.source = s.Source__c;
            r.notesHtml = s.AI_Notes_Markdown__c;
            r.diff = s.DiffToPrev__c;
            r.rawJson = s.RawJSON__c;
            page.items.add(r);
        }

        if (!snaps.isEmpty()) {
            OmniSnapshot__c tail = snaps[snaps.size()-1];
            Long ms = tail.ModifiedAt__c==null ? 0 : tail.ModifiedAt__c.getTime();
            page.nextCursor = String.valueOf(ms) + '|' + tail.Id;
        }
        return page;
    }
}
