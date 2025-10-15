public with sharing class DV_AINotesUtil {

    private static List<String> splitLines(String s){
        if(s==null) return new List<String>();
        String norm = s.replace('\r\n','\n');
        return new List<String>(norm.split('\n', -1));
    }

    public static String deepDiff(String oldJson, String newJson) {
        if (String.isBlank(newJson)) return '';
        
        Map<String,Object> a, b;
        try {
            a = (Map<String,Object>) JSON.deserializeUntyped(String.isBlank(oldJson) ? '{}' : oldJson);
            b = (Map<String,Object>) JSON.deserializeUntyped(newJson);
        } catch (Exception e) {
            return 'Unable to parse JSON for comparison';
        }
        
        return String.join(compareRecursive(a, b, ''), '\n');
    }
    
    private static List<String> compareRecursive(Map<String,Object> a, Map<String,Object> b, String prefix) {
        List<String> out = new List<String>(); 
        Set<String> keys = new Set<String>();
        if (a != null) keys.addAll(a.keySet()); 
        if (b != null) keys.addAll(b.keySet());
        
        // CRITICAL: Skip metadata fields that add noise to diffs
        Set<String> skipFields = new Set<String>{
            'childNames', 'childTag', 'childObject',
            'Language', 'VersionNumber', 'OmniScriptVersionNumber', 'OmniProcessVersionNumber',
            'SubType', 'Type', 'IsActive', 'Active'
        };
        
        for (String k : keys) {
            // Skip metadata fields at root level
            if (prefix == '' && skipFields.contains(k)) continue;
            
            String path = prefix == '' ? k : prefix + '.' + k;
            Boolean hasA = (a != null && a.containsKey(k)), hasB = (b != null && b.containsKey(k));
            
            // Special handling for childPayloads - this is where elements are added/removed
            if (k == 'childPayloads') {
                if (hasA && hasB) {
                    out.addAll(compareChildPayloads((List<Object>)a.get(k), (List<Object>)b.get(k), path));
                } else if (!hasA && hasB) {
                    // New childPayloads added
                    List<Object> newList = (List<Object>)b.get(k);
                    if (newList != null && !newList.isEmpty()) {
                        for (Object item : newList) {
                            if (item instanceof Map<String,Object>) {
                                Map<String,Object> m = (Map<String,Object>)item;
                                String name = m.containsKey('Name') ? String.valueOf(m.get('Name')) : 'Unknown';
                                out.add('+ Added element "' + name + '"');
                            }
                        }
                    }
                }
                continue;
            }
            
            // Skip other metadata fields
            if (skipFields.contains(k)) continue;
            
            if (!hasA && hasB) { 
                out.add('+ Added ' + path + ' = ' + safeSerialize(b.get(k))); 
                continue; 
            }
            if (hasA && !hasB) { 
                out.add('- Removed ' + path + ' (was ' + safeSerialize(a.get(k)) + ')'); 
                continue; 
            }
            
            Object av = a.get(k), bv = b.get(k);
            if (av == null && bv == null) continue;
            if (String.valueOf(av) == String.valueOf(bv)) continue;
            
            if (av instanceof Map<String,Object> && bv instanceof Map<String,Object>)
                out.addAll(compareRecursive((Map<String,Object>)av,(Map<String,Object>)bv,path));
            else if (av instanceof List<Object> && bv instanceof List<Object>)
                out.addAll(compareList((List<Object>)av,(List<Object>)bv,path));
            else
                out.add('~ Changed ' + path + ' from ' + safeSerialize(av) + ' → ' + safeSerialize(bv));
        }
        return out;
    }
    
    private static List<String> compareChildPayloads(List<Object> oldList, List<Object> newList, String prefix) {
        List<String> out = new List<String>();
        
        Map<String, Map<String,Object>> oldByName = new Map<String, Map<String,Object>>();
        Map<String, Map<String,Object>> newByName = new Map<String, Map<String,Object>>();
        
        if (oldList != null) {
            for (Object item : oldList) {
                if (item instanceof Map<String,Object>) {
                    Map<String,Object> m = (Map<String,Object>)item;
                    String name = m.containsKey('Name') ? String.valueOf(m.get('Name')) : null;
                    if (name != null) oldByName.put(name, m);
                }
            }
        }
        
        if (newList != null) {
            for (Object item : newList) {
                if (item instanceof Map<String,Object>) {
                    Map<String,Object> m = (Map<String,Object>)item;
                    String name = m.containsKey('Name') ? String.valueOf(m.get('Name')) : null;
                    if (name != null) newByName.put(name, m);
                }
            }
        }
        
        // Report additions with clear element names and types
        for (String name : newByName.keySet()) {
            if (!oldByName.containsKey(name)) {
                Map<String,Object> element = newByName.get(name);
                String type = element.containsKey('Type') ? String.valueOf(element.get('Type')) : 'Element';
                out.add('+ Added ' + type + ': "' + name + '"');
            }
        }
        
        // Report removals with clear element names and types
        for (String name : oldByName.keySet()) {
            if (!newByName.containsKey(name)) {
                Map<String,Object> element = oldByName.get(name);
                String type = element.containsKey('Type') ? String.valueOf(element.get('Type')) : 'Element';
                out.add('- Removed ' + type + ': "' + name + '"');
            }
        }
        
        // Report meaningful changes within elements (skip metadata noise)
        Set<String> skipElementFields = new Set<String>{
            'SequenceNumber', 'Level', 'ParentElementName', 'IsActive'
        };
        
        for (String name : newByName.keySet()) {
            if (oldByName.containsKey(name)) {
                Map<String,Object> oldItem = oldByName.get(name);
                Map<String,Object> newItem = newByName.get(name);
                
                // Check for meaningful property changes
                for (String key : newItem.keySet()) {
                    if (skipElementFields.contains(key)) continue;
                    
                    Object oldVal = oldItem.get(key);
                    Object newVal = newItem.get(key);
                    
                    if (oldVal == null && newVal == null) continue;
                    if (String.valueOf(oldVal) == String.valueOf(newVal)) continue;
                    
                    // Report significant changes
                    if (key == 'PropertySetConfig') {
                        out.add('~ Modified configuration in "' + name + '"');
                    } else if (!skipElementFields.contains(key)) {
                        out.add('~ Changed ' + key + ' in "' + name + '"');
                    }
                }
            }
        }
        
        return out;
    }
    
    private static List<String> compareList(List<Object> a, List<Object> b, String prefix) {
        List<String> out = new List<String>(); 
        Integer max = Math.max(a == null ? 0 : a.size(), b == null ? 0 : b.size());
        for (Integer i = 0; i < max; i++) {
            String path = prefix + '[' + i + ']'; 
            Boolean hasA = (a != null && i < a.size()), hasB = (b != null && i < b.size());
            if (!hasA && hasB) out.add('+ Added ' + path + ' = ' + safeSerialize(b[i]));
            else if (hasA && !hasB) out.add('- Removed ' + path + ' (was ' + safeSerialize(a[i]) + ')');
            else if (hasA && hasB) {
                Object av = a[i], bv = b[i]; 
                if (String.valueOf(av) == String.valueOf(bv)) continue;
                if (av instanceof Map<String,Object> && bv instanceof Map<String,Object>)
                    out.addAll(compareRecursive((Map<String,Object>)av,(Map<String,Object>)bv,path));
                else if (av instanceof List<Object> && bv instanceof List<Object>)
                    out.addAll(compareList((List<Object>)av,(List<Object>)bv,path));
                else out.add('~ Changed ' + path + ' from ' + safeSerialize(av) + ' → ' + safeSerialize(bv));
            }
        }
        return out;
    }
    
    private static String safeSerialize(Object obj) {
        try {
            return JSON.serialize(obj);
        } catch (Exception e) {
            return String.valueOf(obj);
        }
    }

    public static String aiNotes(String componentName, String diff, String rawJson) {
        String prompt =
            'You are a senior Salesforce OmniStudio developer reviewing component changes. ' +
            'Analyze the DIFF and provide ULTRA-CONCISE bullet points for busy developers.\n\n' +
            'CRITICAL FORMAT REQUIREMENTS:\n' +
            '1. Return ONLY HTML using these tags: <div>, <ul>, <li>, <strong>, <span>\n' +
            '2. Create 3 highlight cards with this EXACT structure:\n' +
            '<div class="highlight-card">\n' +
            '  <div class="card-title">🎯 Key Changes</div>\n' +
            '  <ul>\n' +
            '    <li>Concise change 1 (max 10 words)</li>\n' +
            '    <li>Concise change 2</li>\n' +
            '  </ul>\n' +
            '</div>\n' +
            '<div class="highlight-card warning">\n' +
            '  <div class="card-title">⚠️ Risks</div>\n' +
            '  <ul><li>Risk 1 (max 10 words)</li></ul>\n' +
            '</div>\n' +
            '<div class="highlight-card success">\n' +
            '  <div class="card-title">✅ Test This</div>\n' +
            '  <ul><li>Test scenario 1 (max 10 words)</li></ul>\n' +
            '</div>\n\n' +
            'RULES:\n' +
            '• Each bullet: MAX 10 words\n' +
            '• Focus on WHAT changed (element names, steps)\n' +
            '• Mention user impact ONLY if critical\n' +
            '• NO explanatory text outside cards\n' +
            '• Be specific: "Removed Time1 from Step2" NOT "removed a field"\n\n' +
            'Component: ' + componentName + '\n\n=== DIFF ===\n' + (diff==null?'':diff.left(12000)) +
            '\n\n=== CONTEXT (truncated) ===\n' + (rawJson==null?'':rawJson.left(8000));

        String endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=' +
                          'AIzaSyA-SlQd2BKEyFAfzLPylzpP0vhmRohS6D0';
        
        Map<String,Object> payload = new Map<String,Object>{
            'contents' => new List<Object>{
                new Map<String,Object>{
                    'parts' => new List<Object>{ new Map<String,Object>{ 'text' => prompt } }
                }
            }
        };

        String html = null;
        try{
            HttpRequest req = new HttpRequest();
            req.setMethod('POST'); req.setEndpoint(endpoint);
            req.setHeader('Content-Type','application/json'); req.setTimeout(120000);
            req.setBody(JSON.serialize(payload));
            Http http = new Http(); HttpResponse res = http.send(req);
            if(res.getStatusCode()==200){
                String parsed = parseGeminiHtml(res.getBody());
                if(!String.isBlank(parsed)) html = cleanForUi(parsed);
            }
        } catch(Exception e){
            System.debug('AI Notes error: ' + e.getMessage());
        }

        if(!String.isBlank(html)) return html;

        Integer adds=0, dels=0;
        for(String line : splitLines(diff)){ 
            if(line!=null && line.startsWith('+ ')) adds++; 
            else if(line!=null && line.startsWith('- ')) dels++; 
        }
        
        return '<div class="highlight-card">' +
               '<div class="card-title">🎯 Key Changes</div>' +
               '<ul><li>' + adds + ' additions, ' + dels + ' removals</li></ul>' +
               '</div>' +
               '<div class="highlight-card warning">' +
               '<div class="card-title">⚠️ Risks</div>' +
               '<ul><li>Review data mappings and flow logic</li></ul>' +
               '</div>' +
               '<div class="highlight-card success">' +
               '<div class="card-title">✅ Test This</div>' +
               '<ul><li>Test affected steps and integrations</li></ul>' +
               '</div>';
    }

    private static String parseGeminiHtml(String jsonResponse){
        if(String.isBlank(jsonResponse)) return null;
        try{
            Map<String,Object> parsed = (Map<String,Object>) JSON.deserializeUntyped(jsonResponse);
            List<Object> cand = (List<Object>) parsed.get('candidates');
            if(cand==null || cand.isEmpty()) return null;
            Map<String,Object> first = (Map<String,Object>) cand[0];
            Map<String,Object> content = (Map<String,Object>) first.get('content');
            if(content==null) return null;
            List<Object> parts = (List<Object>) content.get('parts');
            if(parts==null || parts.isEmpty()) return null;
            Map<String,Object> firstPart = (Map<String,Object>) parts[0];
            Object text = firstPart.get('text');
            return (text==null)? null : String.valueOf(text);
        } catch(Exception e){ return null; }
    }
    
    public static String cleanForUi(String html){
        if(String.isBlank(html)) return '';
        String out = html.replace('```html','').replace('```','');
        out = out.replaceAll('(?is)<script[\\s\\S]*?</script>','');
        out = out.replaceAll('(?is)<style[\\s\\S]*?</style>','');
        out = out.replaceAll('`{1,3}','');
        return out;
    }
}