public with sharing class DV_Poller implements Schedulable {
    
    private static final Integer DEFAULT_LOOKBACK_MINUTES = 20;
    private static final Integer MAX_DIFF_LENGTH = 30000; // Safe limit for Long Text Area
    private static final Integer MAX_JSON_LENGTH = 30000; // Safe limit for RawJSON
    
    public void execute(SchedulableContext sc) {
        runSince(System.now().addMinutes(-DEFAULT_LOOKBACK_MINUTES));
    }
    
    @AuraEnabled 
    public static void runNow(Integer lookbackMinutes) {
        runSince(System.now().addMinutes(-(lookbackMinutes == null ? DEFAULT_LOOKBACK_MINUTES : lookbackMinutes)));
    }
    
    private static void runSince(Datetime since) {
        // Process parent objects
        processParent('OmniUiCard', since);
        processParent('OmniProcess', since);
        processParent('OmniDataTransform', since);
        
        // Process child elements - CRITICAL for element-level tracking
        processChild('OmniProcessElement', 'OmniProcessId', 'OmniProcess', 'Element', since);
        processChild('OmniDataTransformItem', 'OmniDataTransformationId', 'OmniDataTransform', 'DR Map Item', since);
    }
    
    // Process parent objects (FlexCard, OmniScript, DataRaptor)
    private static void processParent(String api, Datetime since) {
        String soql = 'SELECT ' + DV_Util.fieldListFor(api) + ' FROM ' + api +
                     ' WHERE LastModifiedDate >= :since ORDER BY LastModifiedDate DESC LIMIT 10000';
        
        List<SObject> recs = Database.query(soql);
        if (recs.isEmpty()) return;
        
        Datetime nowTs = System.now();
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (SObject r : recs) {
            DV_Constants.CompType t = DV_Util.mapType(r);
            if (t == DV_Constants.CompType.Unknown || 
                t == DV_Constants.CompType.OmniProcessElement || 
                t == DV_Constants.CompType.DataMapperItem) continue;
            
            Map<String,Object> m = DV_Util.projectInteresting(r);
            String full = DV_Util.deriveFullName(r, t);
            String base = DV_Util.stripVersion(full);
            
            afterBy.put(full, m);
            
            OmniComponent__c oc = new OmniComponent__c();
            oc.FullName__c = full;
            oc.BaseName__c = base;
            oc.OmniType__c = String.valueOf(t);
            oc.LastSeenModified__c = nowTs;
            
            if (m.containsKey('SubType')) oc.SubType__c = String.valueOf(m.get('SubType'));
            if (m.containsKey('IsActive')) oc.IsActive__c = (Boolean) m.get('IsActive');
            if (m.containsKey('Active')) oc.IsActive__c = (Boolean) m.get('Active');
            
            comps.put(full, oc);
        }
        
        upsertAndSnapshot(comps, afterBy, nowTs, 'Poller', null, null);
    }
    
    // Process child objects (Elements, DataRaptor Items)
    private static void processChild(String childApi, String parentLookup, String parentApi, String childTag, Datetime since) {
        String soqlC = 'SELECT ' + DV_Util.fieldListFor(childApi) + ' FROM ' + childApi +
                      ' WHERE LastModifiedDate >= :since ORDER BY LastModifiedDate DESC LIMIT 10000';
        
        List<SObject> kids = Database.query(soqlC);
        if (kids.isEmpty()) return;
        
        Set<Id> pids = new Set<Id>();
        for (SObject c : kids) {
            if (c.get(parentLookup) != null) pids.add((Id)c.get(parentLookup));
        }
        if (pids.isEmpty()) return;
        
        String soqlP = 'SELECT ' + DV_Util.fieldListFor(parentApi) + ' FROM ' + parentApi + ' WHERE Id IN :pids';
        Map<Id,SObject> parents = new Map<Id,SObject>(Database.query(soqlP));
        
        Datetime nowTs = System.now();
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, String> childNameBy = new Map<String, String>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (SObject c : kids) {
            Id pid = (Id)c.get(parentLookup);
            SObject p = parents.get(pid);
            if (p == null) continue;
            
            DV_Constants.CompType t = DV_Util.mapType(p);
            String full = DV_Util.deriveFullName(p, t);
            String base = DV_Util.stripVersion(full);
            
            Map<String,Object> parentAfter = DV_Util.projectInteresting(p);
            Map<String,Object> childPayload = DV_Util.projectInteresting(c);
            
            parentAfter.put('childObject', childApi);
            parentAfter.put('childName', String.valueOf(c.get('Name')));
            parentAfter.put('childTag', childTag);
            parentAfter.put('childPayload', childPayload);
            
            afterBy.put(full, parentAfter);
            childNameBy.put(full, String.valueOf(c.get('Name')));
            
            OmniComponent__c oc = new OmniComponent__c();
            oc.FullName__c = full;
            oc.BaseName__c = base;
            oc.OmniType__c = String.valueOf(t);
            oc.LastSeenModified__c = nowTs;
            
            if (parentAfter.containsKey('SubType')) oc.SubType__c = String.valueOf(parentAfter.get('SubType'));
            if (parentAfter.containsKey('IsActive')) oc.IsActive__c = (Boolean) parentAfter.get('IsActive');
            if (parentAfter.containsKey('Active')) oc.IsActive__c = (Boolean) parentAfter.get('Active');
            
            comps.put(full, oc);
        }
        
        upsertAndSnapshot(comps, afterBy, nowTs, 'Poller', childTag, childNameBy);
    }
    
    // FIXED: Truncate diffs that are too large
    private static String truncateDiff(String diff) {
        if (String.isBlank(diff)) return diff;
        if (diff.length() <= MAX_DIFF_LENGTH) return diff;
        
        return diff.substring(0, MAX_DIFF_LENGTH) + 
               '\n\n... [TRUNCATED - diff too large, ' + diff.length() + ' chars total]';
    }
    
    // FIXED: Truncate raw JSON that's too large
    private static String truncateRawJson(String rawJson) {
        if (String.isBlank(rawJson)) return rawJson;
        if (rawJson.length() <= MAX_JSON_LENGTH) return rawJson;
        
        return rawJson.substring(0, MAX_JSON_LENGTH) + 
               '\n... [TRUNCATED - JSON too large, ' + rawJson.length() + ' chars total]';
    }
    
    // Upsert components and create snapshots with version awareness
    private static void upsertAndSnapshot(
        Map<String, OmniComponent__c> comps,
        Map<String, Map<String,Object>> afterJsonByFull,
        Datetime nowTs,
        String actor,
        String childTag,
        Map<String,String> childNameBy
    ) {
        if (comps.isEmpty()) return;
        
        // Upsert components by FullName
        Map<String,Id> nameToId = new Map<String,Id>();
        for (OmniComponent__c e : [SELECT Id, FullName__c FROM OmniComponent__c WHERE FullName__c IN :comps.keySet()]) {
            nameToId.put(e.FullName__c, e.Id);
        }
        
        List<OmniComponent__c> ins = new List<OmniComponent__c>();
        List<OmniComponent__c> upd = new List<OmniComponent__c>();
        
        for (String fn : comps.keySet()) {
            OmniComponent__c oc = comps.get(fn);
            if (nameToId.containsKey(fn)) {
                oc.Id = nameToId.get(fn);
                upd.add(oc);
            } else {
                ins.add(oc);
            }
        }
        
        if (!ins.isEmpty()) insert ins;
        if (!upd.isEmpty()) update upd;
        
        // Refresh IDs
        nameToId.clear();
        for (OmniComponent__c e : [SELECT Id, FullName__c FROM OmniComponent__c WHERE FullName__c IN :comps.keySet()]) {
            nameToId.put(e.FullName__c, e.Id);
        }
        
        // Build latest RAW per (component, BaseName, Version) for version-aware diffs
        Map<String,String> prevRawByKey = new Map<String,String>();
        
        for (OmniSnapshot__c s : [
            SELECT Id, OmniComponent__c, BaseName__c, RawJSON__c, Version__c, ModifiedAt__c
            FROM OmniSnapshot__c
            WHERE OmniComponent__c IN :nameToId.values()
            ORDER BY OmniComponent__c ASC, BaseName__c ASC, Version__c DESC, ModifiedAt__c DESC, Id DESC
        ]) {
            String base = s.BaseName__c != null ? s.BaseName__c : '';
            String ver = s.Version__c != null ? String.valueOf(s.Version__c) : '';
            String k = s.OmniComponent__c + '|' + base + '|' + ver;
            
            if (!prevRawByKey.containsKey(k)) {
                prevRawByKey.put(k, s.RawJSON__c);
            }
        }
        
        // Create snapshots - ALWAYS create for baseline ingestion
        List<OmniSnapshot__c> toInsert = new List<OmniSnapshot__c>();
        
        for (String fn : nameToId.keySet()) {
            Map<String,Object> afterM = afterJsonByFull.get(fn);
            String base = DV_Util.stripVersion(fn);
            Decimal v = DV_Util.sniffVersion(afterM);
            
            String prettyAfter = JSON.serializePretty(afterM);
            String versionKey = base + '|' + (v != null ? String.valueOf(v) : '');
            String diffKey = nameToId.get(fn) + '|' + versionKey;
            String prev = prevRawByKey.get(diffKey);
            
            // Calculate diff
            String diff = DV_AINotesUtil.deepDiff(
                String.isBlank(prev) ? '{}' : prev,
                prettyAfter
            );
            
            // FIXED: Always create snapshot for baseline, but skip if no changes for ongoing polling
            Boolean isBaseline = (actor == 'Baseline' || actor == 'Manual Baseline');
            if (!isBaseline && String.isBlank(diff)) {
                continue; // Skip if no changes during regular polling
            }
            
            // FIXED: Truncate both diff and raw JSON if too large
            String safeDiff = truncateDiff(diff);
            String safeRawJson = truncateRawJson(JSON.serialize(afterM));
            
            OmniSnapshot__c snap = new OmniSnapshot__c();
            snap.OmniComponent__c = nameToId.get(fn);
            snap.ModifiedAt__c = nowTs;
            snap.ActorName__c = actor;
            snap.ChangeType__c = String.isBlank(prev) ? 'Insert' : 'Update';
            snap.RawJSON__c = safeRawJson;
            snap.DiffToPrev__c = String.isBlank(safeDiff) ? 'Initial baseline snapshot' : safeDiff;
            snap.BaseName__c = base;
            
            if (v != null) {
                snap.Version__c = v;
                snap.VersionKey__c = base + '_v' + String.valueOf(v);
            }
            
            if (childTag != null) {
                String cn = childNameBy != null ? childNameBy.get(fn) : null;
                snap.Source__c = 'Child: ' + childTag + (String.isBlank(cn) ? '' : ' • ' + cn);
            } else {
                snap.Source__c = isBaseline ? actor : 'Poller';
            }
            
            toInsert.add(snap);
        }
        
        if (!toInsert.isEmpty()) {
            insert toInsert;
            
            List<Id> ids = new List<Id>();
            for (OmniSnapshot__c s : toInsert) {
                if (s.Id != null) ids.add(s.Id);
            }
            
            if (!ids.isEmpty()) {
                System.enqueueJob(new DV_NotesQueue(ids));
            }
        }
    }
    
    // Manual baseline ingestion for all versions of a component
    @AuraEnabled
    public static void ingestBaseAllVersions(String family, String baseName) {
        Datetime nowTs = System.now();
        String actor = 'Baseline';
        
        List<SObject> recs = new List<SObject>();
        
        if (family == 'OmniProcess') {
            recs = Database.query('SELECT ' + DV_Util.fieldListFor('OmniProcess') + ' FROM OmniProcess LIMIT 50000');
        } else if (family == 'Flexcard') {
            recs = Database.query('SELECT ' + DV_Util.fieldListFor('OmniUiCard') + ' FROM OmniUiCard LIMIT 50000');
        } else if (family == 'DataMapper') {
            recs = Database.query('SELECT ' + DV_Util.fieldListFor('OmniDataTransform') + ' FROM OmniDataTransform LIMIT 50000');
        } else {
            throw new AuraHandledException('Unsupported family: ' + family);
        }
        
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (SObject r : recs) {
            DV_Constants.CompType t = DV_Util.mapType(r);
            if (t == DV_Constants.CompType.Unknown || 
                t == DV_Constants.CompType.OmniProcessElement || 
                t == DV_Constants.CompType.DataMapperItem) continue;
            
            Map<String,Object> m = DV_Util.projectInteresting(r);
            String full = DV_Util.deriveFullName(r, t);
            String base = DV_Util.stripVersion(full);
            
            if (base != baseName) continue;
            
            afterBy.put(full, m);
            
            OmniComponent__c oc = new OmniComponent__c();
            oc.FullName__c = full;
            oc.BaseName__c = base;
            oc.OmniType__c = String.valueOf(t);
            oc.LastSeenModified__c = nowTs;
            
            if (m.containsKey('SubType')) oc.SubType__c = String.valueOf(m.get('SubType'));
            if (m.containsKey('IsActive')) oc.IsActive__c = (Boolean) m.get('IsActive');
            if (m.containsKey('Active')) oc.IsActive__c = (Boolean) m.get('Active');
            
            comps.put(full, oc);
        }
        
        if (afterBy.isEmpty()) {
            throw new AuraHandledException('No versions found for ' + baseName + ' in ' + family + '.');
        }
        
        upsertAndSnapshot(comps, afterBy, nowTs, actor, null, null);
    }
    
    // Baseline all components in a family
    @AuraEnabled
    public static void ingestAllByFamily(String family) {
        Datetime nowTs = System.now();
        String actor = 'Manual Baseline';
        
        List<SObject> recs;
        
        if (family == 'OmniProcess') {
            recs = Database.query('SELECT ' + DV_Util.fieldListFor('OmniProcess') + ' FROM OmniProcess LIMIT 50000');
        } else if (family == 'Flexcard') {
            recs = Database.query('SELECT ' + DV_Util.fieldListFor('OmniUiCard') + ' FROM OmniUiCard LIMIT 50000');
        } else if (family == 'DataMapper') {
            recs = Database.query('SELECT ' + DV_Util.fieldListFor('OmniDataTransform') + ' FROM OmniDataTransform LIMIT 50000');
        } else {
            throw new AuraHandledException('Unsupported family: ' + family);
        }
        
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (SObject r : recs) {
            DV_Constants.CompType t = DV_Util.mapType(r);
            if (t == DV_Constants.CompType.Unknown || 
                t == DV_Constants.CompType.OmniProcessElement || 
                t == DV_Constants.CompType.DataMapperItem) continue;
            
            Map<String,Object> m = DV_Util.projectInteresting(r);
            String full = DV_Util.deriveFullName(r, t);
            String base = DV_Util.stripVersion(full);
            
            afterBy.put(full, m);
            
            OmniComponent__c oc = new OmniComponent__c();
            oc.FullName__c = full;
            oc.BaseName__c = base;
            oc.OmniType__c = String.valueOf(t);
            oc.LastSeenModified__c = nowTs;
            
            if (m.containsKey('SubType')) oc.SubType__c = String.valueOf(m.get('SubType'));
            if (m.containsKey('IsActive')) oc.IsActive__c = (Boolean) m.get('IsActive');
            if (m.containsKey('Active')) oc.IsActive__c = (Boolean) m.get('Active');
            
            comps.put(full, oc);
        }
        
        if (!afterBy.isEmpty()) {
            upsertAndSnapshot(comps, afterBy, nowTs, actor, null, null);
        }
    }
}