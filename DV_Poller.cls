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
        
        upsertAndSnapshot(comps, afterBy, nowTs, 'Poller', null, null, null);
    }
    
    // CRITICAL FIX: Compare previous state to only capture CHANGED elements
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
        
        // NEW: Get previous state to compare
        Map<Id, Map<String, Map<String,Object>>> prevChildMapByParent = getPreviousChildState(pids, childApi, parentLookup);
        
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, String> childNameBy = new Map<String, String>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        Map<String, ElementChangeSummary> changesByFull = new Map<String, ElementChangeSummary>();
        
        for (Id pid : pids) {
            SObject p = parents.get(pid);
            if (p == null) continue;
            
            DV_Constants.CompType t = DV_Util.mapType(p);
            String full = DV_Util.deriveFullName(p, t);
            String base = DV_Util.stripVersion(full);
            
            Map<String,Object> parentAfter = DV_Util.projectInteresting(p);
            
            // Current children
            List<SObject> currentChildren = allChildrenByParent.get(pid);
            Map<String, Map<String,Object>> currentChildMap = new Map<String, Map<String,Object>>();
            List<Map<String,Object>> childPayloads = new List<Map<String,Object>>();
            List<String> childNames = new List<String>();
            
            if (currentChildren != null) {
                for (SObject c : currentChildren) {
                    String childName = String.valueOf(c.get('Name'));
                    Map<String,Object> childPayload = DV_Util.projectInteresting(c);
                    childPayloads.add(childPayload);
                    childNames.add(childName);
                    currentChildMap.put(childName, childPayload);
                }
            }
            
            // Previous children
            Map<String, Map<String,Object>> prevChildMap = prevChildMapByParent.get(pid);
            if (prevChildMap == null) prevChildMap = new Map<String, Map<String,Object>>();
            
            // COMPARE: Find added and removed elements
            ElementChangeSummary changeSummary = compareElements(prevChildMap, currentChildMap, childTag, p);
            changesByFull.put(full, changeSummary);
            
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
        
        upsertAndSnapshot(comps, afterBy, nowTs, 'Poller', childTag, childNameBy, changesByFull);
    }
    
    // NEW: Get previous child state from last snapshot
    private static Map<Id, Map<String, Map<String,Object>>> getPreviousChildState(Set<Id> parentIds, String childApi, String parentLookup) {
        Map<Id, Map<String, Map<String,Object>>> result = new Map<Id, Map<String, Map<String,Object>>>();
        
        // Build component ID to parent ID mapping
        Map<Id, Id> componentToParentId = new Map<Id, Id>();
        List<OmniComponent__c> components = [
            SELECT Id, FullName__c, OmniType__c 
            FROM OmniComponent__c 
            LIMIT 10000
        ];
        
        // Query latest snapshots - REMOVED RawJSON__c filter since it's Long Text Area
        List<OmniSnapshot__c> latestSnaps = [
            SELECT Id, RawJSON__c, OmniComponent__c, ModifiedAt__c
            FROM OmniSnapshot__c
            ORDER BY ModifiedAt__c DESC, Id DESC
            LIMIT 1000
        ];
        
        // Group snapshots by component
        Map<Id, OmniSnapshot__c> latestByComponent = new Map<Id, OmniSnapshot__c>();
        for (OmniSnapshot__c snap : latestSnaps) {
            if (!latestByComponent.containsKey(snap.OmniComponent__c)) {
                latestByComponent.put(snap.OmniComponent__c, snap);
            }
        }
        
        // Parse RawJSON to extract child state
        for (Id componentId : latestByComponent.keySet()) {
            OmniSnapshot__c snap = latestByComponent.get(componentId);
            
            if (String.isBlank(snap.RawJSON__c)) continue;
            
            try {
                Map<String,Object> snapData = (Map<String,Object>) JSON.deserializeUntyped(snap.RawJSON__c);
                if (snapData.containsKey('childPayloads')) {
                    List<Object> childPayloads = (List<Object>) snapData.get('childPayloads');
                    Map<String, Map<String,Object>> childMap = new Map<String, Map<String,Object>>();
                    
                    for (Object cpObj : childPayloads) {
                        if (cpObj instanceof Map<String,Object>) {
                            Map<String,Object> cp = (Map<String,Object>) cpObj;
                            if (cp.containsKey('Name')) {
                                String childName = String.valueOf(cp.get('Name'));
                                childMap.put(childName, cp);
                            }
                        }
                    }
                    
                    if (!childMap.isEmpty()) {
                        // Store by component ID (caller will map to parent ID)
                        result.put(componentId, childMap);
                    }
                }
            } catch (Exception e) {
                System.debug('Error parsing previous snapshot: ' + e.getMessage());
            }
        }
        
        return result;
    }
    
    // NEW: Compare element lists and build change summary
    private static ElementChangeSummary compareElements(
        Map<String, Map<String,Object>> prevMap, 
        Map<String, Map<String,Object>> currMap,
        String childTag,
        SObject parent
    ) {
        ElementChangeSummary summary = new ElementChangeSummary();
        summary.added = new List<ElementChange>();
        summary.removed = new List<ElementChange>();
        summary.modified = new List<ElementChange>();
        
        // Get parent element name if it exists
        String parentElementName = parent.get('Name') != null ? String.valueOf(parent.get('Name')) : 'Root';
        
        // Find added elements
        for (String childName : currMap.keySet()) {
            if (!prevMap.containsKey(childName)) {
                Map<String,Object> childData = currMap.get(childName);
                ElementChange ec = new ElementChange();
                ec.elementName = childName;
                ec.elementType = childData.containsKey('Type') ? String.valueOf(childData.get('Type')) : childTag;
                ec.parentElementName = getParentElementName(childData, parentElementName);
                ec.details = buildElementDetails(childData);
                summary.added.add(ec);
            }
        }
        
        // Find removed elements
        for (String childName : prevMap.keySet()) {
            if (!currMap.containsKey(childName)) {
                Map<String,Object> childData = prevMap.get(childName);
                ElementChange ec = new ElementChange();
                ec.elementName = childName;
                ec.elementType = childData.containsKey('Type') ? String.valueOf(childData.get('Type')) : childTag;
                ec.parentElementName = getParentElementName(childData, parentElementName);
                ec.details = buildElementDetails(childData);
                summary.removed.add(ec);
            }
        }
        
        // Find modified elements (same name, different content)
        for (String childName : currMap.keySet()) {
            if (prevMap.containsKey(childName)) {
                Map<String,Object> prevData = prevMap.get(childName);
                Map<String,Object> currData = currMap.get(childName);
                
                // Simple comparison - enhance as needed
                String prevJson = JSON.serialize(prevData);
                String currJson = JSON.serialize(currData);
                
                if (prevJson != currJson) {
                    ElementChange ec = new ElementChange();
                    ec.elementName = childName;
                    ec.elementType = currData.containsKey('Type') ? String.valueOf(currData.get('Type')) : childTag;
                    ec.parentElementName = getParentElementName(currData, parentElementName);
                    ec.details = buildElementDiff(prevData, currData);
                    summary.modified.add(ec);
                }
            }
        }
        
        return summary;
    }
    
    private static String getParentElementName(Map<String,Object> childData, String defaultParent) {
        if (childData.containsKey('ParentElementName') && childData.get('ParentElementName') != null) {
            return String.valueOf(childData.get('ParentElementName'));
        }
        return defaultParent;
    }
    
    private static String buildElementDetails(Map<String,Object> data) {
        List<String> details = new List<String>();
        if (data.containsKey('Type')) details.add('Type: ' + data.get('Type'));
        if (data.containsKey('SequenceNumber')) details.add('Sequence: ' + data.get('SequenceNumber'));
        if (data.containsKey('Level')) details.add('Level: ' + data.get('Level'));
        return String.join(details, ', ');
    }
    
    private static String buildElementDiff(Map<String,Object> prev, Map<String,Object> curr) {
        List<String> changes = new List<String>();
        
        Set<String> allKeys = new Set<String>();
        allKeys.addAll(prev.keySet());
        allKeys.addAll(curr.keySet());
        
        for (String key : allKeys) {
            Object prevVal = prev.get(key);
            Object currVal = curr.get(key);
            
            if (prevVal != currVal && String.valueOf(prevVal) != String.valueOf(currVal)) {
                changes.add(key + ': ' + prevVal + ' → ' + currVal);
            }
        }
        
        return String.join(changes, '; ');
    }
    
    private static String truncate(String txt, Integer max) {
        if (String.isBlank(txt) || txt.length() <= max) return txt;
        return txt.substring(0, max) + '\n\n... [TRUNCATED - ' + txt.length() + ' chars total]';
    }
    
    // Single unified method with optional parameters
    private static void upsertAndSnapshot(
        Map<String, OmniComponent__c> comps,
        Map<String, Map<String,Object>> afterJsonByFull,
        Datetime nowTs,
        String actor,
        String childTag,
        Map<String,String> childNameBy,
        Map<String, ElementChangeSummary> changesByFull
    ) {
        // changesByFull can be null for non-child processes
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
            
            String compactJson;
            try {
                compactJson = JSON.serialize(afterM);
            } catch (Exception e) {
                System.debug('JSON serialization failed for ' + fn + ': ' + e.getMessage());
                continue;
            }
            
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
            
            // NEW: Store element changes in new field
            if (changesByFull != null && changesByFull.containsKey(fn)) {
                ElementChangeSummary changeSummary = changesByFull.get(fn);
                snap.put('ElementChangesSummary__c', buildSourceText(childTag, childNameBy != null ? childNameBy.get(fn) : null, changeSummary));
            }
            
            // Keep original Source__c as picklist value
            if (childTag != null) {
                snap.Source__c = 'Child: ' + childTag;
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
    
    // NEW: Build rich source text with element changes
    private static String buildSourceText(String childTag, String allChildNames, ElementChangeSummary changeSummary) {
        List<String> parts = new List<String>();
        parts.add('Child: ' + childTag);
        
        if (changeSummary != null) {
            if (!changeSummary.added.isEmpty()) {
                parts.add('\n\nADDED (' + changeSummary.added.size() + '):');
                for (ElementChange ec : changeSummary.added) {
                    parts.add('\n  • ' + ec.elementName + ' (' + ec.elementType + ')');
                    if (!String.isBlank(ec.parentElementName)) {
                        parts.add(' under ' + ec.parentElementName);
                    }
                }
            }
            
            if (!changeSummary.removed.isEmpty()) {
                parts.add('\n\nREMOVED (' + changeSummary.removed.size() + '):');
                for (ElementChange ec : changeSummary.removed) {
                    parts.add('\n  • ' + ec.elementName + ' (' + ec.elementType + ')');
                    if (!String.isBlank(ec.parentElementName)) {
                        parts.add(' from ' + ec.parentElementName);
                    }
                }
            }
            
            if (!changeSummary.modified.isEmpty()) {
                parts.add('\n\nMODIFIED (' + changeSummary.modified.size() + '):');
                for (ElementChange ec : changeSummary.modified) {
                    parts.add('\n  • ' + ec.elementName + ' (' + ec.elementType + ')');
                }
            }
        }
        
        if (!String.isBlank(allChildNames)) {
            parts.add('\n\nAll Elements: ' + allChildNames);
        }
        
        return String.join(parts, '');
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
        
        upsertAndSnapshot(comps, afterBy, nowTs, actor, null, null, null);
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
            upsertAndSnapshot(comps, afterBy, nowTs, actor, null, null, null);
        }
    }
    
    public class ElementChangeSummary {
        public List<ElementChange> added;
        public List<ElementChange> removed;
        public List<ElementChange> modified;
    }
    
    public class ElementChange {
        public String elementName;
        public String elementType;
        public String parentElementName;
        public String details;
    }
}