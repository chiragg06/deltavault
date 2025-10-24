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
        Map<String, ElementChangeSummary> changesByFull = new Map<String, ElementChangeSummary>();
        
        for (SObject r : recs) {
            DV_Constants.CompType t = DV_Util.mapType(r);
            if (t == DV_Constants.CompType.Unknown || 
                t == DV_Constants.CompType.OmniProcessElement || 
                t == DV_Constants.CompType.DataMapperItem) continue;
            
            Map<String,Object> m = DV_Util.projectInteresting(r);
            String full = DV_Util.deriveFullName(r, t);
            String base = DV_Util.stripVersion(full);
            
            // CRITICAL FIX: For FlexCards - detect PropertySetConfig changes
            if (t == DV_Constants.CompType.Flexcard) {
                ElementChangeSummary fcChanges = analyzeFlexCardChanges(full, m);
                if (fcChanges != null) {
                    changesByFull.put(full, fcChanges);
                }
            }
            
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
        
        upsertAndSnapshot(comps, afterBy, nowTs, 'Poller', null, null, changesByFull);
    }
    
    // CRITICAL FIX: Analyze FlexCard PropertySetConfig changes
    private static ElementChangeSummary analyzeFlexCardChanges(String fullName, Map<String,Object> currentData) {
        try {
            // Get previous snapshot's PropertySetConfig
            List<OmniComponent__c> compList = [
                SELECT Id FROM OmniComponent__c 
                WHERE FullName__c = :fullName 
                LIMIT 1
            ];
            
            if (compList.isEmpty()) {
                return null; // First snapshot - no previous to compare
            }
            
            Id componentId = compList[0].Id;
            
            List<OmniSnapshot__c> snaps = [
                SELECT RawJSON__c 
                FROM OmniSnapshot__c 
                WHERE OmniComponent__c = :componentId 
                ORDER BY ModifiedAt__c DESC 
                LIMIT 1
            ];
            
            if (snaps.isEmpty() || String.isBlank(snaps[0].RawJSON__c)) {
                return null; // No previous snapshot
            }
            
            String prevRaw = DV_Util.cleanStringForJson(snaps[0].RawJSON__c);
            Map<String,Object> prevData = (Map<String,Object>) JSON.deserializeUntyped(prevRaw);
            
            String prevPSC = prevData.containsKey('PropertySetConfig') ? 
                            String.valueOf(prevData.get('PropertySetConfig')) : '';
            String currPSC = currentData.containsKey('PropertySetConfig') ? 
                            String.valueOf(currentData.get('PropertySetConfig')) : '';
            
            // CRITICAL: Compare as text, not JSON
            if (prevPSC != currPSC) {
                ElementChangeSummary summary = new ElementChangeSummary();
                summary.added = new List<ElementChange>();
                summary.removed = new List<ElementChange>();
                summary.modified = new List<ElementChange>();
                
                ElementChange ec = new ElementChange();
                ec.elementName = 'PropertySetConfig';
                ec.elementType = 'FlexCard Configuration';
                ec.parentElementName = 'Root';
                
                Integer charDiff = Math.abs(currPSC.length() - prevPSC.length());
                ec.details = 'UI Configuration modified (' + charDiff + ' chars changed)';
                
                summary.modified.add(ec);
                
                return summary;
            }
            
            return null; // No changes
        } catch (Exception e) {
            System.debug('Error analyzing FlexCard changes: ' + e.getMessage());
            return null;
        }
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
        
        // CRITICAL: Get previous state
        Map<Id, Map<String, Map<String,Object>>> prevChildMapByParent = getPreviousChildState(pids, childApi, parentLookup);
        Map<Id, Map<String,Object>> prevParentDataByParent = getPreviousParentData(pids);
        
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
            
            Id componentId = getComponentIdForParent(pid, full);
            Map<String, Map<String,Object>> prevChildMap = prevChildMapByParent.get(componentId);
            if (prevChildMap == null) prevChildMap = new Map<String, Map<String,Object>>();
            
            Map<String,Object> prevParentData = prevParentDataByParent.get(componentId);
            if (prevParentData == null) prevParentData = new Map<String,Object>();
            
            // CRITICAL FIX: Compare with proper change detection
            ElementChangeSummary changeSummary = compareElementsAndParent(
                prevChildMap, currentChildMap, 
                prevParentData, parentAfter,
                childTag, p
            );
            
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
    
    private static Id getComponentIdForParent(Id parentId, String fullName) {
        List<OmniComponent__c> comps = [
            SELECT Id 
            FROM OmniComponent__c 
            WHERE FullName__c = :fullName 
            LIMIT 1
        ];
        
        return comps.isEmpty() ? null : comps[0].Id;
    }
    
    private static Map<Id, Map<String, Map<String,Object>>> getPreviousChildState(Set<Id> parentIds, String childApi, String parentLookup) {
        Map<Id, Map<String, Map<String,Object>>> result = new Map<Id, Map<String, Map<String,Object>>>();
        
        List<OmniComponent__c> relevantComponents = [
            SELECT Id FROM OmniComponent__c 
            WHERE Id IN (
                SELECT OmniComponent__c 
                FROM OmniSnapshot__c 
                WHERE OmniComponent__c != NULL
            )
        ];
        
        Map<Id, OmniSnapshot__c> prevByComponent = new Map<Id, OmniSnapshot__c>();
        
        for (OmniComponent__c comp : relevantComponents) {
            List<OmniSnapshot__c> compSnaps = [
                SELECT RawJSON__c 
                FROM OmniSnapshot__c
                WHERE OmniComponent__c = :comp.Id
                ORDER BY ModifiedAt__c DESC
                LIMIT 1
            ];
            
            if (!compSnaps.isEmpty()) {
                prevByComponent.put(comp.Id, compSnaps[0]);
            }
        }
        
        for (Id componentId : prevByComponent.keySet()) {
            OmniSnapshot__c snap = prevByComponent.get(componentId);
            
            if (String.isBlank(snap.RawJSON__c)) continue;
            
            try {
                String cleanedJson = DV_Util.cleanStringForJson(snap.RawJSON__c);
                Map<String,Object> snapData = (Map<String,Object>) JSON.deserializeUntyped(cleanedJson);
                
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
                        result.put(componentId, childMap);
                    }
                }
            } catch (Exception e) {
                System.debug('Error parsing previous snapshot for ' + componentId + ': ' + e.getMessage());
            }
        }
        
        return result;
    }
    
    private static Map<Id, Map<String,Object>> getPreviousParentData(Set<Id> parentIds) {
        Map<Id, Map<String,Object>> result = new Map<Id, Map<String,Object>>();
        
        List<OmniComponent__c> relevantComponents = [
            SELECT Id FROM OmniComponent__c 
            WHERE Id IN (SELECT OmniComponent__c FROM OmniSnapshot__c WHERE OmniComponent__c != NULL)
        ];
        
        for (OmniComponent__c comp : relevantComponents) {
            List<OmniSnapshot__c> compSnaps = [
                SELECT RawJSON__c 
                FROM OmniSnapshot__c
                WHERE OmniComponent__c = :comp.Id
                ORDER BY ModifiedAt__c DESC
                LIMIT 1
            ];
            
            if (!compSnaps.isEmpty() && !String.isBlank(compSnaps[0].RawJSON__c)) {
                try {
                    String cleanedJson = DV_Util.cleanStringForJson(compSnaps[0].RawJSON__c);
                    Map<String,Object> snapData = (Map<String,Object>) JSON.deserializeUntyped(cleanedJson);
                    result.put(comp.Id, snapData);
                } catch (Exception e) {
                    System.debug('Error parsing previous parent data: ' + e.getMessage());
                }
            }
        }
        
        return result;
    }
    
    // CRITICAL FIX: Proper comparison - only detect REAL changes
    private static ElementChangeSummary compareElementsAndParent(
        Map<String, Map<String,Object>> prevChildMap, 
        Map<String, Map<String,Object>> currChildMap,
        Map<String,Object> prevParentData,
        Map<String,Object> currParentData,
        String childTag,
        SObject parent
    ) {
        ElementChangeSummary summary = new ElementChangeSummary();
        summary.added = new List<ElementChange>();
        summary.removed = new List<ElementChange>();
        summary.modified = new List<ElementChange>();
        
        String parentElementName = parent.get('Name') != null ? String.valueOf(parent.get('Name')) : 'Root';
        
        // === PART 1: Compare child elements - ONLY additions and deletions ===
        
        // Find ADDED elements
        for (String childName : currChildMap.keySet()) {
            if (!prevChildMap.containsKey(childName)) {
                Map<String,Object> childData = currChildMap.get(childName);
                ElementChange ec = new ElementChange();
                ec.elementName = childName;
                ec.elementType = childData.containsKey('Type') ? String.valueOf(childData.get('Type')) : childTag;
                ec.parentElementName = getParentElementName(childData, parentElementName);
                ec.details = buildDetailedElementInfo(childData);
                summary.added.add(ec);
            }
        }
        
        // Find REMOVED elements
        for (String childName : prevChildMap.keySet()) {
            if (!currChildMap.containsKey(childName)) {
                Map<String,Object> childData = prevChildMap.get(childName);
                ElementChange ec = new ElementChange();
                ec.elementName = childName;
                ec.elementType = childData.containsKey('Type') ? String.valueOf(childData.get('Type')) : childTag;
                ec.parentElementName = getParentElementName(childData, parentElementName);
                ec.details = buildDetailedElementInfo(childData);
                summary.removed.add(ec);
            }
        }
        
        // === PART 2: Compare parent-level fields (EXCLUDING PropertySetConfig) ===
        
        String componentType = String.valueOf(parent.getSObjectType().getDescribe().getName());
        
        if (componentType == 'OmniProcess') {
            checkParentField(prevParentData, currParentData, 'CustomJavaScript', 'Custom JavaScript', summary);
            checkParentField(prevParentData, currParentData, 'Language', 'Language', summary);
            checkParentBooleanField(prevParentData, currParentData, 'IsActive', 'Active Status', summary);
        } else if (componentType == 'OmniDataTransform') {
            checkParentField(prevParentData, currParentData, 'Type', 'DataRaptor Type', summary);
            checkParentField(prevParentData, currParentData, 'InputType', 'Input Type', summary);
            checkParentField(prevParentData, currParentData, 'OutputType', 'Output Type', summary);
            checkParentBooleanField(prevParentData, currParentData, 'IsActive', 'Active Status', summary);
        }
        
        return summary;
    }
    
    private static void checkParentField(
        Map<String,Object> prevData, 
        Map<String,Object> currData, 
        String fieldName, 
        String displayName,
        ElementChangeSummary summary
    ) {
        Object prevVal = prevData.get(fieldName);
        Object currVal = currData.get(fieldName);
        
        if (prevVal == null && currVal == null) return;
        if (String.valueOf(prevVal) == String.valueOf(currVal)) return;
        
        ElementChange ec = new ElementChange();
        ec.elementName = displayName;
        ec.elementType = 'Parent Configuration';
        ec.parentElementName = 'Root';
        
        if (prevVal == null) {
            ec.details = 'Added: ' + truncateValue(currVal);
        } else if (currVal == null) {
            ec.details = 'Removed: ' + truncateValue(prevVal);
        } else {
            ec.details = 'Changed: ' + truncateValue(prevVal) + ' → ' + truncateValue(currVal);
        }
        
        summary.modified.add(ec);
    }
    
    private static void checkParentBooleanField(
        Map<String,Object> prevData, 
        Map<String,Object> currData, 
        String fieldName, 
        String displayName,
        ElementChangeSummary summary
    ) {
        Object prevVal = prevData.get(fieldName);
        Object currVal = currData.get(fieldName);
        
        if (prevVal == currVal) return;
        
        ElementChange ec = new ElementChange();
        ec.elementName = displayName;
        ec.elementType = 'Parent Configuration';
        ec.parentElementName = 'Root';
        ec.details = 'Changed: ' + prevVal + ' → ' + currVal;
        
        summary.modified.add(ec);
    }
    
    private static String truncateValue(Object val) {
        if (val == null) return 'null';
        String str = String.valueOf(val);
        if (str.length() > 50) {
            return str.substring(0, 47) + '...';
        }
        return str;
    }
    
    private static String getParentElementName(Map<String,Object> childData, String defaultParent) {
        if (childData.containsKey('ParentElementName') && childData.get('ParentElementName') != null) {
            return String.valueOf(childData.get('ParentElementName'));
        }
        return defaultParent;
    }
    
    private static String buildDetailedElementInfo(Map<String,Object> data) {
        List<String> details = new List<String>();
        
        String elemType = data.containsKey('Type') ? String.valueOf(data.get('Type')) : '';
        
        if (data.containsKey('Type')) {
            details.add('Type: ' + elemType);
        }
        if (data.containsKey('Level')) {
            details.add('Level: ' + data.get('Level'));
        }
        
        if (data.containsKey('InputFieldName')) {
            details.add('Input: ' + data.get('InputFieldName'));
        }
        if (data.containsKey('OutputFieldName')) {
            details.add('Output: ' + data.get('OutputFieldName'));
        }
        
        return String.join(details, ', ');
    }
    
    private static String truncate(String txt, Integer max) {
        if (String.isBlank(txt) || txt.length() <= max) return txt;
        return txt.substring(0, max) + '\n\n... [TRUNCATED - ' + txt.length() + ' chars total]';
    }
    
    // CRITICAL FIX: Only create snapshots when ACTUAL changes detected
    private static void upsertAndSnapshot(
        Map<String, OmniComponent__c> comps,
        Map<String, Map<String,Object>> afterJsonByFull,
        Datetime nowTs,
        String actor,
        String childTag,
        Map<String,String> childNameBy,
        Map<String, ElementChangeSummary> changesByFull
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
            
            // CRITICAL FIX: Check if ACTUAL changes exist
            Boolean isBaseline = (actor == 'Baseline' || actor == 'Manual Baseline');
            Boolean hasChanges = false;
            
            if (changesByFull != null && changesByFull.containsKey(fn)) {
                ElementChangeSummary summary = changesByFull.get(fn);
                hasChanges = (!summary.added.isEmpty() || 
                             !summary.removed.isEmpty() || 
                             !summary.modified.isEmpty());
            }
            
            // CRITICAL: Skip if not baseline AND no actual changes
            if (!isBaseline && !hasChanges) {
                System.debug('Skipping snapshot for ' + fn + ' - no element changes detected');
                continue;
            }
            
            System.debug('Creating snapshot for ' + fn + ' - hasChanges=' + hasChanges + ', isBaseline=' + isBaseline);
            
            OmniSnapshot__c snap = new OmniSnapshot__c();
            snap.OmniComponent__c = nameToId.get(fn);
            snap.ModifiedAt__c = nowTs;
            snap.ActorName__c = actor;
            snap.ChangeType__c = isBaseline ? 'Insert' : 'Update';
            snap.RawJSON__c = truncate(compactJson, MAX_JSON_LENGTH);
            snap.DiffToPrev__c = isBaseline ? 'Initial baseline snapshot' : 'See Element Changes tab';
            snap.BaseName__c = base;
            
            if (v != null) {
                snap.Version__c = v;
                snap.VersionKey__c = base + '_v' + String.valueOf(v);
            }
            
            // Store element changes summary
            if (changesByFull != null && changesByFull.containsKey(fn)) {
                ElementChangeSummary changeSummary = changesByFull.get(fn);
                snap.ElementChangesSummary__c = buildElementSummaryText(childTag, childNameBy != null ? childNameBy.get(fn) : null, changeSummary);
                snap.ElementsArray__c = DV_Util.buildElementsArrayJson(afterM);
            }
            
            if (childTag != null) {
                snap.Source__c = 'Child: ' + childTag;
            } else {
                snap.Source__c = isBaseline ? actor : 'Poller';
            }
            
            toInsert.add(snap);
        }
        
        System.debug('Inserting ' + toInsert.size() + ' snapshots');
        
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
    
    private static String buildElementSummaryText(String childTag, String allChildNames, ElementChangeSummary changeSummary) {
        List<String> parts = new List<String>();
        
        if (changeSummary != null) {
            if (!changeSummary.added.isEmpty()) {
                parts.add('=== ADDED (' + changeSummary.added.size() + ') ===');
                for (ElementChange ec : changeSummary.added) {
                    parts.add('+ ' + ec.elementName + ' (' + ec.elementType + ')' + 
                             (String.isBlank(ec.parentElementName) ? '' : ' under ' + ec.parentElementName));
                    if (!String.isBlank(ec.details)) {
                        parts.add('  Details: ' + ec.details);
                    }
                }
            }
            
            if (!changeSummary.removed.isEmpty()) {
                parts.add('\n=== REMOVED (' + changeSummary.removed.size() + ') ===');
                for (ElementChange ec : changeSummary.removed) {
                    parts.add('- ' + ec.elementName + ' (' + ec.elementType + ')' +
                             (String.isBlank(ec.parentElementName) ? '' : ' from ' + ec.parentElementName));
                    if (!String.isBlank(ec.details)) {
                        parts.add('  Details: ' + ec.details);
                    }
                }
            }
            
            if (!changeSummary.modified.isEmpty()) {
                parts.add('\n=== MODIFIED (' + changeSummary.modified.size() + ') ===');
                for (ElementChange ec : changeSummary.modified) {
                    parts.add('~ ' + ec.elementName + ' (' + ec.elementType + ')');
                    if (!String.isBlank(ec.details)) {
                        parts.add('  Changes: ' + ec.details);
                    }
                }
            }
        }
        
        return String.join(parts, '\n');
    }
    
    private static String getApiNameForFamily(String family) {
        if (String.isBlank(family)) return null;
        
        family = family.toLowerCase();
        
        if (family == 'flexcard' || family == 'card' || family == 'omniuicard') {
            return 'OmniUiCard';
        } else if (family == 'omniscript' || family == 'script' || family == 'omniprocess') {
            return 'OmniProcess';
        } else if (family == 'dataraptor' || family == 'dr' || 
                   family == 'datamapper' || family == 'omnidatatransform') {
            return 'OmniDataTransform';
        } else if (family == 'integrationprocedure' || family == 'ip') {
            return 'OmniProcess';
        }
        
        return null;
    }
    
    @AuraEnabled
    public static void ingestBaseAllVersions(String family, String baseName) {
        String apiName = getApiNameForFamily(family);
        if (String.isBlank(apiName)) {
            throw new AuraHandledException('Invalid family: ' + family);
        }
        
        Datetime nowTs = System.now();
        String actor = 'Baseline';
        
        String soql = 'SELECT ' + DV_Util.fieldListFor(apiName) + ' FROM ' + apiName + ' LIMIT 50000';
        List<SObject> recs = Database.query(soql);
        
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (SObject r : recs) {
            DV_Constants.CompType t = DV_Util.mapType(r);
            if (t == DV_Constants.CompType.Unknown) continue;
            
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
            throw new AuraHandledException('No versions found for ' + baseName);
        }
        
        upsertAndSnapshot(comps, afterBy, nowTs, actor, null, null, null);
    }
    
    @AuraEnabled
    public static void ingestAllByFamily(String family) {
        String apiName = getApiNameForFamily(family);
        if (String.isBlank(apiName)) {
            throw new AuraHandledException('Invalid family: ' + family);
        }
        
        Datetime nowTs = System.now();
        String actor = 'Manual Baseline';
        
        String soql = 'SELECT ' + DV_Util.fieldListFor(apiName) + ' FROM ' + apiName + ' LIMIT 50000';
        List<SObject> recs = Database.query(soql);
        
        Map<String, Map<String,Object>> afterBy = new Map<String, Map<String,Object>>();
        Map<String, OmniComponent__c> comps = new Map<String, OmniComponent__c>();
        
        for (SObject r : recs) {
            DV_Constants.CompType t = DV_Util.mapType(r);
            if (t == DV_Constants.CompType.Unknown) continue;
            
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