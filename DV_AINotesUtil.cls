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
        
        Set<String> skipFields = new Set<String>{
            'childNames', 'childTag', 'childObject',
            'Language', 'VersionNumber', 'OmniScriptVersionNumber', 'OmniProcessVersionNumber',
            'SubType', 'Type', 'IsActive', 'Active', 'SequenceNumber', 'Level'
        };
        
        for (String k : keys) {
            if (prefix == '' && skipFields.contains(k)) continue;
            
            String path = prefix == '' ? k : prefix + '.' + k;
            Boolean hasA = (a != null && a.containsKey(k)), hasB = (b != null && b.containsKey(k));
            
            if (k == 'childPayloads') {
                if (hasA && hasB) {
                    out.addAll(compareChildPayloads((List<Object>)a.get(k), (List<Object>)b.get(k), path));
                } else if (!hasA && hasB) {
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
        
        for (String name : newByName.keySet()) {
            if (!oldByName.containsKey(name)) {
                Map<String,Object> element = newByName.get(name);
                String type = element.containsKey('Type') ? String.valueOf(element.get('Type')) : 'Element';
                out.add('+ Added ' + type + ': "' + name + '"');
            }
        }
        
        for (String name : oldByName.keySet()) {
            if (!newByName.containsKey(name)) {
                Map<String,Object> element = oldByName.get(name);
                String type = element.containsKey('Type') ? String.valueOf(element.get('Type')) : 'Element';
                out.add('- Removed ' + type + ': "' + name + '"');
            }
        }
        
        Set<String> skipElementFields = new Set<String>{
            'SequenceNumber', 'Level', 'ParentElementName', 'IsActive'
        };
        
        for (String name : newByName.keySet()) {
            if (oldByName.containsKey(name)) {
                Map<String,Object> oldItem = oldByName.get(name);
                Map<String,Object> newItem = newByName.get(name);
                
                for (String key : newItem.keySet()) {
                    if (skipElementFields.contains(key)) continue;
                    
                    Object oldVal = oldItem.get(key);
                    Object newVal = newItem.get(key);
                    
                    if (oldVal == null && newVal == null) continue;
                    if (String.valueOf(oldVal) == String.valueOf(newVal)) continue;
                    
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

    // CRITICAL: Element-focused AI Notes generation
    public static String aiNotes(String componentName, String diff, String rawJson, String elementChangesSummary) {
        // Build context from element changes summary
        String elementContext = '';
        if (!String.isBlank(elementChangesSummary)) {
            elementContext = '\n\n=== ELEMENT CHANGES (Primary Focus) ===\n' + elementChangesSummary;
        }
        
        String prompt =
            'You are a senior Salesforce OmniStudio developer. Analyze ELEMENT CHANGES and provide THREE concise cards.\n\n' +
            'CRITICAL FORMAT:\n' +
            '1. Return ONLY HTML using: <div>, <ul>, <li>, <strong>\n' +
            '2. Create 3 cards with EXACT structure:\n\n' +
            '<div class="highlight-card">\n' +
            '  <div class="card-title">🎯 Key Changes</div>\n' +
            '  <ul>\n' +
            '    <li>Brief one-liner about element change (max 12 words)</li>\n' +
            '    <li>Another specific change</li>\n' +
            '  </ul>\n' +
            '</div>\n' +
            '<div class="highlight-card warning">\n' +
            '  <div class="card-title">⚠️ Risks</div>\n' +
            '  <ul><li>Specific risk (max 12 words)</li></ul>\n' +
            '</div>\n' +
            '<div class="highlight-card success">\n' +
            '  <div class="card-title">✅ Test This</div>\n' +
            '  <ul><li>Specific test scenario (max 12 words)</li></ul>\n' +
            '</div>\n\n' +
            'RULES:\n' +
            '• Each bullet: MAX 12 words\n' +
            '• Focus ONLY on elements from ELEMENT CHANGES section\n' +
            '• Be specific: "Added Email element to Step2" NOT "added field"\n' +
            '• For ADDED: mention element name and parent\n' +
            '• For REMOVED: mention what was deleted\n' +
            '• For MODIFIED: mention configuration change\n' +
            '• NO generic statements - use actual element names\n' +
            '• NO explanatory text outside cards\n' +
            '• If no element changes, say "No element-level changes detected"\n\n' +
            'Component: ' + componentName + elementContext;

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

        // FALLBACK: Parse element changes summary directly
        if (!String.isBlank(elementChangesSummary)) {
            return buildFallbackHtmlFromElementSummary(elementChangesSummary);
        }

        // Final fallback
        return '<div class="highlight-card">' +
               '<div class="card-title">🎯 Key Changes</div>' +
               '<ul><li>No element-level changes detected</li></ul>' +
               '</div>' +
               '<div class="highlight-card warning">' +
               '<div class="card-title">⚠️ Risks</div>' +
               '<ul><li>Review overall configuration changes</li></ul>' +
               '</div>' +
               '<div class="highlight-card success">' +
               '<div class="card-title">✅ Test This</div>' +
               '<ul><li>Verify component still functions correctly</li></ul>' +
               '</div>';
    }

    // CRITICAL: Build concise fallback summaries from ElementChangesSummary
    private static String buildFallbackHtmlFromElementSummary(String elementSummary) {
        List<String> lines = splitLines(elementSummary);
        List<String> added = new List<String>();
        List<String> removed = new List<String>();
        List<String> modified = new List<String>();
        
        String currentSection = '';
        for (String line : lines) {
            if (line.contains('=== ADDED')) {
                currentSection = 'ADDED';
            } else if (line.contains('=== REMOVED')) {
                currentSection = 'REMOVED';
            } else if (line.contains('=== MODIFIED')) {
                currentSection = 'MODIFIED';
            } else if (line.startsWith('+ ')) {
                String content = line.substring(2).trim();
                if (content.length() > 80) content = content.substring(0, 77) + '...';
                added.add(content);
            } else if (line.startsWith('- ')) {
                String content = line.substring(2).trim();
                if (content.length() > 80) content = content.substring(0, 77) + '...';
                removed.add(content);
            } else if (line.startsWith('~ ')) {
                String content = line.substring(2).trim();
                if (content.length() > 80) content = content.substring(0, 77) + '...';
                modified.add(content);
            }
        }
        
        // Build Key Changes card
        String keyChangesHtml = '<div class="highlight-card"><div class="card-title">🎯 Key Changes</div><ul>';
        
        Integer totalChanges = added.size() + removed.size() + modified.size();
        if (totalChanges == 0) {
            keyChangesHtml += '<li>No element-level changes detected</li>';
        } else {
            // Show max 3 items, prioritize added/removed over modified
            Integer itemsShown = 0;
            
            for (String item : added) {
                if (itemsShown >= 3) break;
                keyChangesHtml += '<li>Added: ' + escapeHtml(item) + '</li>';
                itemsShown++;
            }
            
            for (String item : removed) {
                if (itemsShown >= 3) break;
                keyChangesHtml += '<li>Removed: ' + escapeHtml(item) + '</li>';
                itemsShown++;
            }
            
            for (String item : modified) {
                if (itemsShown >= 3) break;
                keyChangesHtml += '<li>Modified: ' + escapeHtml(item) + '</li>';
                itemsShown++;
            }
            
            if (totalChanges > 3) {
                keyChangesHtml += '<li>' + (totalChanges - 3) + ' more changes</li>';
            }
        }
        keyChangesHtml += '</ul></div>';
        
        // Build Risks card
        String risksHtml = '<div class="highlight-card warning"><div class="card-title">⚠️ Risks</div><ul>';
        if (removed.size() > 0) {
            risksHtml += '<li>Removed elements may break dependent flows</li>';
        } else if (modified.size() > 0) {
            risksHtml += '<li>Configuration changes need validation testing</li>';
        } else if (added.size() > 0) {
            risksHtml += '<li>New elements need integration testing</li>';
        } else {
            risksHtml += '<li>Review configuration for unexpected changes</li>';
        }
        risksHtml += '</ul></div>';
        
        // Build Test This card
        String testHtml = '<div class="highlight-card success"><div class="card-title">✅ Test This</div><ul>';
        if (added.size() > 0) {
            testHtml += '<li>Verify new elements function as expected</li>';
        } else if (removed.size() > 0) {
            testHtml += '<li>Check dependent components still work</li>';
        } else if (modified.size() > 0) {
            testHtml += '<li>Test modified element configurations</li>';
        } else {
            testHtml += '<li>Run full regression test suite</li>';
        }
        testHtml += '</ul></div>';
        
        return keyChangesHtml + risksHtml + testHtml;
    }
    
    private static String escapeHtml(String text) {
        if (String.isBlank(text)) return '';
        return text.replace('&', '&amp;')
                   .replace('<', '&lt;')
                   .replace('>', '&gt;')
                   .replace('"', '&quot;')
                   .replace('\'', '&#39;');
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