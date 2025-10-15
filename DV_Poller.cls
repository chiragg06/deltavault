public with sharing class DV_Poller implements Schedulable {
    
    private static final Integer DEFAULT_LOOKBACK_MINUTES = 20;
    private static final Integer MAX_DIFF_LENGTH = 30000;
    private static final Integer MAX_JSON_LENGTH = 30000;
    
    public void execute(SchedulableContext sc) {
        runSince(System.now().addMinutes(-DEFAULT_LOOKBACK_MINUTES));
    }
    
    @AuraEnabled 
    public static void runNow(Integer lookbackMinutes) {
        runSince(System.now().addMinutes(-(lookbackMinutes == null ? DEFAULT_LOOKBACK_MINUTES : lookbackMinutes)));
    }
    
    private static void runSince(Datetime since) {
        processParent('OmniUiCard', since);
        processParent('OmniProcess', since);
        processParent('OmniDataTransform', since);
        
        processChild('OmniProcessElement', 'OmniProcessId', 'OmniProcess', 'Element', since);
        processChild('OmniDataTransformItem', 'OmniDataTransformationId', 'OmniDataTransform', 'DR Map Item', since);
    }
    
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
    
    private static void processChild(String childApi, String parentLookup, String parentApi, String childTag, Datetime since) {
        String soqlC = 'SELECT ' + DV_Util.fieldListFor(childApi) + ' FROM ' + childApi +
                      ' WHERE LastModifiedDate >= :since ORDER BY LastModifiedDate DESC LIMIT 10000';
        
        List<SObject> modifiedKids = Database.query(soqlC);
        if (modifiedKids.isEmpty()) return;
        
        Set<Id> pids = new Set<Id>();
        for (SObject c : modifiedKids) {
            if (c.get(parentLookup) != null) pids.add((Id)c.get(parentLookup));
        }
        if (pids.isEmpty()) return;
        
        String soqlP = 'SELECT ' + DV_Util.fieldListFor(parentApi) + ' FROM ' + parentApi + ' WHERE Id IN :pids';
        Map<Id,SObject> parents = new Map<Id,SObject>(Database.query(soqlP));
        
        String soqlAllChildren = 'SELECT ' + DV_Util.fieldListFor(childApi) + ' FROM ' + childApi +
                                ' WHERE ' + parentLookup + ' IN :pids ORDER BY Name ASC';
        List<SObject> allKids = Database.query(soqlAllChildren);
        
        Datetime nowTs = System.now();
        
        Map<Id, List<SObject>> allChildrenByParent = new Map<Id, List<SObject>>();
        for (SObject c : allKids) {
            Id pid = (Id)c.get(parentLookup);
            if (!allChildrenByParent.containsKey(pid)) {
                allChildrenByParent.put(pid, new List<SObject>());
            }
            allChildrenByParent.get(pid).add(c);
        }
        
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, String> childNameBy = new Map<String, String>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (Id pid : pids) {
            SObject p = parents.get(pid);
            if (p == null) continue;
            
            DV_Constants.CompType t = DV_Util.mapType(p);
            String full = DV_Util.deriveFullName(p, t);
            String base = DV_Util.stripVersion(full);
            
            Map<String,Object> parentAfter = DV_Util.projectInteresting(p);
            
            List<Map<String,Object>> childPayloads = new List<Map<String,Object>>();
            List<String> childNames = new List<String>();
            
            List<SObject> allChildren = allChildrenByParent.get(pid);
            if (allChildren != null) {
                for (SObject c : allChildren) {
                    Map<String,Object> childPayload = DV_Util.projectInteresting(c);
                    childPayloads.add(childPayload);
                    childNames.add(String.valueOf(c.get('Name')));
                }
            }
            
            parentAfter.put('childObject', childApi);
            parentAfter.put('childTag', childTag);
            parentAfter.put('childPayloads', childPayloads);
            parentAfter.put('childNames', childNames);
            
            afterBy.put(full, parentAfter);
            
            String childNamesList = String.join(childNames, ', ');
            if (childNamesList.length() > 200) {
                childNamesList = childNamesList.substring(0, 197) + '...';
            }
            childNameBy.put(full, childNamesList);
            
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
    
    private static String truncate(String txt, Integer max) {
        if (String.isBlank(txt) || txt.length() <= max) return txt;
        return txt.substring(0, max) + '\n\n... [TRUNCATED - ' + txt.length() + ' chars total]';
    }
    
    private static void upsertAndSnapshot(
        Map<String, OmniComponent__c> comps,
        Map<String, Map<String,Object>> afterJsonByFull,
        Datetime nowTs,
        String actor,
        String childTag,
        Map<String,String> childNameBy
    ) {
        if (comps.isEmpty()) return;
        
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
        
        nameToId.clear();
        for (OmniComponent__c e : [SELECT Id, FullName__c FROM OmniComponent__c WHERE FullName__c IN :comps.keySet()]) {
            nameToId.put(e.FullName__c, e.Id);
        }
        
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
        
        List<OmniSnapshot__c> toInsert = new List<OmniSnapshot__c>();
        
        for (String fn : nameToId.keySet()) {
            Map<String,Object> afterM = afterJsonByFull.get(fn);
            String base = DV_Util.stripVersion(fn);
            Decimal v = DV_Util.sniffVersion(afterM);
            
            // Serialize to JSON - should work now since all strings are pre-cleaned
            String compactJson;
            try {
                compactJson = JSON.serialize(afterM);
            } catch (Exception e) {
                System.debug('JSON serialization failed for ' + fn + ': ' + e.getMessage());
                System.debug('Keys in Map: ' + afterM.keySet());
                continue; // Skip this component
            }
            
            // Pretty print
            String prettyAfter;
            try {
                prettyAfter = JSON.serializePretty(JSON.deserializeUntyped(compactJson));
            } catch (Exception e) {
                prettyAfter = compactJson;
            }
            
            String versionKey = base + '|' + (v != null ? String.valueOf(v) : '');
            String diffKey = nameToId.get(fn) + '|' + versionKey;
            String prev = prevRawByKey.get(diffKey);
            
            String diff = DV_AINotesUtil.deepDiff(
                String.isBlank(prev) ? '{}' : prev,
                prettyAfter
            );
            
            Boolean isBaseline = (actor == 'Baseline' || actor == 'Manual Baseline');
            if (!isBaseline && String.isBlank(diff)) continue;
            
            OmniSnapshot__c snap = new OmniSnapshot__c();
            snap.OmniComponent__c = nameToId.get(fn);
            snap.ModifiedAt__c = nowTs;
            snap.ActorName__c = actor;
            snap.ChangeType__c = String.isBlank(prev) ? 'Insert' : 'Update';
            snap.RawJSON__c = truncate(compactJson, MAX_JSON_LENGTH);
            snap.DiffToPrev__c = String.isBlank(diff) ? 'Initial baseline snapshot' : truncate(diff, MAX_DIFF_LENGTH);
            snap.BaseName__c = base;
            
            if (v != null) {
                snap.Version__c = v;
                snap.VersionKey__c = base + '_v' + String.valueOf(v);
            }
            
            if (childTag != null) {
                String cn = childNameBy != null ? childNameBy.get(fn) : null;
                String sourceText = 'Child: ' + childTag;
                if (!String.isBlank(cn)) {
                    Integer maxChildNameLength = 255 - sourceText.length() - 3;
                    if (cn.length() > maxChildNameLength) {
                        cn = cn.substring(0, maxChildNameLength - 3) + '...';
                    }
                    sourceText += ' • ' + cn;
                }
                snap.Source__c = sourceText;
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