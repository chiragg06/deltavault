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
            
            // CRITICAL: Extract FlexCard elements from PropertySetConfig
            if (t == DV_Constants.CompType.Flexcard && m.containsKey('PropertySetConfig')) {
                ElementChangeSummary fcChanges = extractFlexCardElements(r.Id, m);
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
    
    // CRITICAL: Extract FlexCard elements from PropertySetConfig
    private static ElementChangeSummary extractFlexCardElements(Id componentId, Map<String,Object> parentData) {
        try {
            if (!parentData.containsKey('PropertySetConfig')) return null;
            
            Object pscObj = parentData.get('PropertySetConfig');
            if (pscObj == null) return null;
            
            Map<String,Object> psc;
            if (pscObj instanceof String) {
                psc = (Map<String,Object>) JSON.deserializeUntyped((String)pscObj);
            } else {
                psc = (Map<String,Object>) pscObj;
            }
            
            Map<String, FCElement> currentElements = new Map<String, FCElement>();
            
            // Parse states array
            if (psc.containsKey('states')) {
                List<Object> states = (List<Object>) psc.get('states');
                Integer stateIndex = 0;
                
                for (Object stateObj : states) {
                    Map<String,Object> state = (Map<String,Object>) stateObj;
                    String stateName = state.containsKey('name') ? String.valueOf(state.get('name')) : 'State' + stateIndex;
                    
                    parseFlexCardComponents(state, currentElements, stateName, '');
                    stateIndex++;
                }
            }
            
            // Get previous elements from last snapshot
            Map<String, FCElement> prevElements = getPreviousFlexCardElements(componentId);
            
            return compareFlexCardElements(prevElements, currentElements);
            
        } catch (Exception e) {
            System.debug('Error extracting FlexCard elements: ' + e.getMessage());
            return null;
        }
    }
    
    private static void parseFlexCardComponents(Map<String,Object> node, Map<String, FCElement> elements, String stateName, String path) {
        if (!node.containsKey('components')) return;
        
        Map<String,Object> components = (Map<String,Object>) node.get('components');
        
        for (String layerKey : components.keySet()) {
            Map<String,Object> layer = (Map<String,Object>) components.get(layerKey);
            
            if (layer.containsKey('children')) {
                List<Object> children = (List<Object>) layer.get('children');
                
                for (Object childObj : children) {
                    Map<String,Object> child = (Map<String,Object>) childObj;
                    
                    String elementName = child.containsKey('name') ? String.valueOf(child.get('name')) : 'Unknown';
                    String elementType = child.containsKey('element') ? String.valueOf(child.get('element')) : 'Unknown';
                    String elementLabel = '';
                    
                    if (child.containsKey('property')) {
                        Map<String,Object> props = (Map<String,Object>) child.get('property');
                        if (props.containsKey('label')) {
                            elementLabel = String.valueOf(props.get('label'));
                        }
                        if (props.containsKey('propertyObj')) {
                            Map<String,Object> propObj = (Map<String,Object>) props.get('propertyObj');
                            if (propObj.containsKey('label')) {
                                elementLabel = String.valueOf(propObj.get('label'));
                            }
                        }
                    }
                    
                    String fullPath = String.isBlank(path) ? stateName : path + ' > ' + elementName;
                    
                    FCElement elem = new FCElement();
                    elem.name = elementName;
                    elem.type = elementType;
                    elem.label = elementLabel;
                    elem.stateName = stateName;
                    elem.path = fullPath;
                    
                    String uniqueKey = fullPath + '|' + elementType;
                    elements.put(uniqueKey, elem);
                    
                    // Recurse if nested
                    if (child.containsKey('children')) {
                        parseFlexCardComponents(child, elements, stateName, fullPath);
                    }
                }
            }
        }
    }
    
    private static Map<String, FCElement> getPreviousFlexCardElements(Id componentId) {
        Map<String, FCElement> result = new Map<String, FCElement>();
        
        try {
            // Get SECOND most recent snapshot (first is current being created)
            List<OmniSnapshot__c> snaps = [
                SELECT RawJSON__c 
                FROM OmniSnapshot__c 
                WHERE OmniComponent__c = :componentId 
                ORDER BY ModifiedAt__c DESC 
                LIMIT 2
            ];
            
            if (snaps.size() < 2 || String.isBlank(snaps[1].RawJSON__c)) {
                return result; // No previous snapshot
            }
            
            // CRITICAL FIX: Clean JSON before parsing
            String cleanedJson = DV_Util.cleanStringForJson(snaps[1].RawJSON__c);
            Map<String,Object> prevData = (Map<String,Object>) JSON.deserializeUntyped(cleanedJson);
            
            if (prevData.containsKey('PropertySetConfig')) {
                Object pscObj = prevData.get('PropertySetConfig');
                Map<String,Object> psc;
                
                if (pscObj instanceof String) {
                    String pscString = DV_Util.cleanStringForJson((String)pscObj);
                    psc = (Map<String,Object>) JSON.deserializeUntyped(pscString);
                } else {
                    psc = (Map<String,Object>) pscObj;
                }
                
                if (psc.containsKey('states')) {
                    List<Object> states = (List<Object>) psc.get('states');
                    Integer stateIndex = 0;
                    
                    for (Object stateObj : states) {
                        Map<String,Object> state = (Map<String,Object>) stateObj;
                        String stateName = state.containsKey('name') ? String.valueOf(state.get('name')) : 'State' + stateIndex;
                        
                        parseFlexCardComponents(state, result, stateName, '');
                        stateIndex++;
                    }
                }
            }
        } catch (Exception e) {
            System.debug('Error getting previous FlexCard elements: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
        }
        
        return result;
    }
    
    private static ElementChangeSummary compareFlexCardElements(Map<String, FCElement> prev, Map<String, FCElement> curr) {
        ElementChangeSummary summary = new ElementChangeSummary();
        summary.added = new List<ElementChange>();
        summary.removed = new List<ElementChange>();
        summary.modified = new List<ElementChange>();
        
        // Find added
        for (String key : curr.keySet()) {
            if (!prev.containsKey(key)) {
                FCElement elem = curr.get(key);
                ElementChange ec = new ElementChange();
                ec.elementName = elem.name;
                ec.elementType = elem.type;
                ec.parentElementName = elem.stateName;
                ec.details = 'Label: ' + elem.label;
                summary.added.add(ec);
            }
        }
        
        // Find removed
        for (String key : prev.keySet()) {
            if (!curr.containsKey(key)) {
                FCElement elem = prev.get(key);
                ElementChange ec = new ElementChange();
                ec.elementName = elem.name;
                ec.elementType = elem.type;
                ec.parentElementName = elem.stateName;
                ec.details = 'Label: ' + elem.label;
                summary.removed.add(ec);
            }
        }
        
        // Find modified (same key but different properties)
        for (String key : curr.keySet()) {
            if (prev.containsKey(key)) {
                FCElement prevElem = prev.get(key);
                FCElement currElem = curr.get(key);
                
                if (prevElem.label != currElem.label || prevElem.path != currElem.path) {
                    ElementChange ec = new ElementChange();
                    ec.elementName = currElem.name;
                    ec.elementType = currElem.type;
                    ec.parentElementName = currElem.stateName;
                    ec.details = 'Label changed: ' + prevElem.label + ' → ' + currElem.label;
                    summary.modified.add(ec);
                }
            }
        }
        
        return summary;
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
        
        // CRITICAL FIX: Get previous state BEFORE we create new snapshots
        Map<Id, Map<String, Map<String,Object>>> prevChildMapByParent = getPreviousChildState(pids, childApi, parentLookup);
        
        System.debug('=== CHILD COMPARISON DEBUG ===');
        System.debug('Parent IDs being processed: ' + pids.size());
        System.debug('Previous state found for: ' + prevChildMapByParent.size() + ' parents');
        
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
            
            // Get component ID to look up previous state
            Id componentId = getComponentIdForParent(pid, full);
            Map<String, Map<String,Object>> prevChildMap = prevChildMapByParent.get(componentId);
            if (prevChildMap == null) prevChildMap = new Map<String, Map<String,Object>>();
            
            System.debug('Component: ' + full);
            System.debug('  Current children: ' + currentChildMap.keySet());
            System.debug('  Previous children: ' + prevChildMap.keySet());
            
            ElementChangeSummary changeSummary = compareElements(prevChildMap, currentChildMap, childTag, p);
            
            System.debug('  Changes detected: Added=' + changeSummary.added.size() + 
                        ', Removed=' + changeSummary.removed.size() + 
                        ', Modified=' + changeSummary.modified.size());
            
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
    
    // Helper to get component ID from parent ID
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
        
        // Build map of component IDs we're interested in
        Map<Id, Id> parentIdToComponentId = new Map<Id, Id>();
        
        // Get components for these parent IDs
        List<OmniComponent__c> relevantComponents = [
            SELECT Id, FullName__c, OmniType__c 
            FROM OmniComponent__c 
            WHERE Id IN (
                SELECT OmniComponent__c 
                FROM OmniSnapshot__c 
                WHERE OmniComponent__c != NULL
                
            )
        ];
        
        // Get the SECOND most recent snapshot per component (skip the current one being created)
        Map<Id, OmniSnapshot__c> prevByComponent = new Map<Id, OmniSnapshot__c>();
        
        for (OmniComponent__c comp : relevantComponents) {
            List<OmniSnapshot__c> compSnaps = [
                SELECT Id, RawJSON__c, OmniComponent__c, ModifiedAt__c
                FROM OmniSnapshot__c
                WHERE OmniComponent__c = :comp.Id
                ORDER BY ModifiedAt__c DESC, Id DESC
                LIMIT 2
            ];
            
            // Use the SECOND snapshot if it exists (first is the one we just created)
            if (compSnaps.size() > 1) {
                prevByComponent.put(comp.Id, compSnaps[1]);
            } else if (compSnaps.size() == 1) {
                // If only one exists, use it (this is a baseline)
                prevByComponent.put(comp.Id, compSnaps[0]);
            }
        }
        
        // Parse previous snapshots
        for (Id componentId : prevByComponent.keySet()) {
            OmniSnapshot__c snap = prevByComponent.get(componentId);
            
            if (String.isBlank(snap.RawJSON__c)) continue;
            
            try {
                // CRITICAL FIX: Clean JSON before parsing
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
                System.debug('Raw JSON length: ' + (snap.RawJSON__c != null ? snap.RawJSON__c.length() : 0));
            }
        }
        
        return result;
    }
    
    // ENHANCED: Extract more meaningful fields
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
        
        String parentElementName = parent.get('Name') != null ? String.valueOf(parent.get('Name')) : 'Root';
        
        // Find added
        for (String childName : currMap.keySet()) {
            if (!prevMap.containsKey(childName)) {
                Map<String,Object> childData = currMap.get(childName);
                ElementChange ec = new ElementChange();
                ec.elementName = childName;
                ec.elementType = childData.containsKey('Type') ? String.valueOf(childData.get('Type')) : childTag;
                ec.parentElementName = getParentElementName(childData, parentElementName);
                ec.details = buildDetailedElementInfo(childData);
                summary.added.add(ec);
            }
        }
        
        // Find removed
        for (String childName : prevMap.keySet()) {
            if (!currMap.containsKey(childName)) {
                Map<String,Object> childData = prevMap.get(childName);
                ElementChange ec = new ElementChange();
                ec.elementName = childName;
                ec.elementType = childData.containsKey('Type') ? String.valueOf(childData.get('Type')) : childTag;
                ec.parentElementName = getParentElementName(childData, parentElementName);
                ec.details = buildDetailedElementInfo(childData);
                summary.removed.add(ec);
            }
        }
        
        Set<String> skipFields = new Set<String>{
            'SequenceNumber', 'Level', 'ParentElementName', 'IsActive', 'SystemModstamp',
            'LastModifiedDate', 'LastReferencedDate', 'LastViewedDate', 'CreatedDate', 
            'CreatedById', 'LastModifiedById', 'MayEdit', 'IsDeleted', 'IsLocked'
        };
        
        // Find modified
        for (String childName : currMap.keySet()) {
            if (prevMap.containsKey(childName)) {
                Map<String,Object> prevData = prevMap.get(childName);
                Map<String,Object> currData = currMap.get(childName);
                
                List<String> changes = new List<String>();
                
                for (String key : currData.keySet()) {
                    if (skipFields.contains(key)) continue;
                    
                    Object prevVal = prevData.get(key);
                    Object currVal = currData.get(key);
                    
                    if (prevVal == null && currVal == null) continue;
                    if (String.valueOf(prevVal) == String.valueOf(currVal)) continue;
                    
                    changes.add(key + ': ' + prevVal + ' → ' + currVal);
                }
                
                if (!changes.isEmpty()) {
                    ElementChange ec = new ElementChange();
                    ec.elementName = childName;
                    ec.elementType = currData.containsKey('Type') ? String.valueOf(currData.get('Type')) : childTag;
                    ec.parentElementName = getParentElementName(currData, parentElementName);
                    ec.details = String.join(changes, '; ');
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
    
    // ENHANCED: Extract meaningful fields per element type
    private static String buildDetailedElementInfo(Map<String,Object> data) {
        List<String> details = new List<String>();
        
        String elemType = data.containsKey('Type') ? String.valueOf(data.get('Type')) : '';
        
        // For OmniProcessElement
        if (data.containsKey('Type')) {
            details.add('Type: ' + elemType);
        }
        if (data.containsKey('Level')) {
            details.add('Level: ' + data.get('Level'));
        }
        
        // For DataRaptor Items
        if (data.containsKey('InputFieldName')) {
            details.add('Input: ' + data.get('InputFieldName'));
        }
        if (data.containsKey('OutputFieldName')) {
            details.add('Output: ' + data.get('OutputFieldName'));
        }
        if (data.containsKey('FormulaExpression') && data.get('FormulaExpression') != null) {
            String formula = String.valueOf(data.get('FormulaExpression'));
            if (formula.length() > 50) formula = formula.substring(0, 47) + '...';
            details.add('Formula: ' + formula);
        }
        
        return String.join(details, ', ');
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
            
            if (changesByFull != null && changesByFull.containsKey(fn)) {
                ElementChangeSummary changeSummary = changesByFull.get(fn);
                snap.ElementChangesSummary__c = buildElementSummaryText(childTag, childNameBy != null ? childNameBy.get(fn) : null, changeSummary);
            }
            
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
    
    public class FCElement {
        public String name;
        public String type;
        public String label;
        public String stateName;
        public String path;
    }
}