public with sharing class DV_AINotesUtil {

    // --- simple unified line diff (for fallback) ---
    public static String unifiedDiff(String oldText, String newText) {
        List<String> o = splitLines(oldText), n = splitLines(newText);
        Integer i=0, j=0; List<String> out = new List<String>();
        out.add('--- OLD'); out.add('+++ NEW');
        while(i<o.size() || j<n.size()){
            if(i<o.size() && j<n.size() && String.valueOf(o[i])==String.valueOf(n[j])){ i++; j++; continue; }
            if(i<o.size()){ out.add('- ' + (o[i]==null?'':o[i])); i++; }
            if(j<n.size()){ out.add('+ ' + (n[j]==null?'':n[j])); j++; }
        }
        return String.join(out, '\n');
    }
    private static List<String> splitLines(String s){
        if(s==null) return new List<String>();
        String norm = s.replace('\r\n','\n');
        return new List<String>(norm.split('\n', -1));
    }

    // --- deep JSON diff (maps + arrays) ---
    public static String deepDiff(String oldJson, String newJson) {
        if (String.isBlank(newJson)) return '';
        Map<String,Object> a = (Map<String,Object>) JSON.deserializeUntyped(String.isBlank(oldJson) ? '{}' : oldJson);
        Map<String,Object> b = (Map<String,Object>) JSON.deserializeUntyped(newJson);
        return String.join(compareRecursive(a, b, ''), '\n');
    }
    private static List<String> compareRecursive(Map<String,Object> a, Map<String,Object> b, String prefix) {
        List<String> out = new List<String>(); Set<String> keys = new Set<String>();
        if (a != null) keys.addAll(a.keySet()); if (b != null) keys.addAll(b.keySet());
        for (String k : keys) {
            String path = prefix == '' ? k : prefix + '.' + k;
            Boolean hasA = (a != null && a.containsKey(k)), hasB = (b != null && b.containsKey(k));
            if (!hasA && hasB) { out.add('+ Added ' + path + ' = ' + JSON.serialize(b.get(k))); continue; }
            if (hasA && !hasB) { out.add('- Removed ' + path + ' (was ' + JSON.serialize(a.get(k)) + ')'); continue; }
            Object av = a.get(k), bv = b.get(k);
            if (av == null && bv == null) continue;
            if (String.valueOf(av) == String.valueOf(bv)) continue;
            if (av instanceof Map<String,Object> && bv instanceof Map<String,Object>)
                out.addAll(compareRecursive((Map<String,Object>)av,(Map<String,Object>)bv,path));
            else if (av instanceof List<Object> && bv instanceof List<Object>)
                out.addAll(compareList((List<Object>)av,(List<Object>)bv,path));
            else
                out.add('~ Changed ' + path + ' from ' + JSON.serialize(av) + ' → ' + JSON.serialize(bv));
        }
        return out;
    }
    private static List<String> compareList(List<Object> a, List<Object> b, String prefix) {
        List<String> out = new List<String>(); Integer max = Math.max(a == null ? 0 : a.size(), b == null ? 0 : b.size());
        for (Integer i = 0; i < max; i++) {
            String path = prefix + '[' + i + ']'; Boolean hasA = (a != null && i < a.size()), hasB = (b != null && i < b.size());
            if (!hasA && hasB) out.add('+ Added ' + path + ' = ' + JSON.serialize(b[i]));
            else if (hasA && !hasB) out.add('- Removed ' + path + ' (was ' + JSON.serialize(a[i]) + ')');
            else if (hasA && hasB) {
                Object av = a[i], bv = b[i]; if (String.valueOf(av) == String.valueOf(bv)) continue;
                if (av instanceof Map<String,Object> && bv instanceof Map<String,Object>)
                    out.addAll(compareRecursive((Map<String,Object>)av,(Map<String,Object>)bv,path));
                else if (av instanceof List<Object> && bv instanceof List<Object>)
                    out.addAll(compareList((List<Object>)av,(List<Object>)bv,path));
                else out.add('~ Changed ' + path + ' from ' + JSON.serialize(av) + ' → ' + JSON.serialize(bv));
            }
        }
        return out;
    }

    // --- AI notes: OmniStudio - UPDATED FOR HIGHLIGHT CARDS ---
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

        // HARDCODED API KEY - Replace with your actual key
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

        // Fallback: Simple cards
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

    // --- AI notes for Apex (kept) ---
    public static String aiNotesApex(String className, String diff, String body) {
        String prompt =
            'You are a senior Salesforce Apex reviewer. Based on the DIFF and APEX BODY, ' +
            'produce concise release-notes style HTML for developers. ' +
            'Use only: <p>, <ul>, <li>, <strong>, <code>. Sections: Summary, Impact, Risks, Test Ideas. ' +
            'Keep under 180 words.\n\nClass: ' + className + '\n\n=== DIFF ===\n' + (diff==null?'':diff) +
            '\n\n=== APEX BODY (truncated) ===\n' + (body==null?'':body.left(8000));
        try{
            // HARDCODED API KEY
            String endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=' +
                              'AIzaSyA-SlQd2BKEyFAfzLPylzpP0vhmRohS6D0';
            
            Map<String,Object> payload = new Map<String,Object>{
                'contents' => new List<Object>{
                    new Map<String,Object>{
                        'parts' => new List<Object>{ new Map<String,Object>{ 'text' => prompt } }
                    }
                }
            };
            HttpRequest req = new HttpRequest(); req.setMethod('POST'); req.setEndpoint(endpoint);
            req.setHeader('Content-Type','application/json'); req.setTimeout(120000);
            req.setBody(JSON.serialize(payload));
            Http http = new Http(); HttpResponse res = http.send(req);
            if(res.getStatusCode()==200) return cleanForUi(parseGeminiHtml(res.getBody()));
        } catch(Exception e){}
        Integer adds=0, dels=0;
        for(String line : splitLines(diff)){ if(line!=null && line.startsWith('+ ')) adds++; else if(line!=null && line.startsWith('- ')) dels++; }
        return '<p><strong>Summary:</strong> Updated <code>' + enc(className) + '</code> with ' + adds + ' additions and ' + dels + ' removals.</p>' +
               '<ul><li><strong>Impact:</strong> Potential logic or API behavior changes.</li>' +
               '<li><strong>Risks:</strong> Null checks, bulkification, security.</li>' +
               '<li><strong>Test Ideas:</strong> Re-run unit tests for changed methods.</li></ul>';
    }

    // --- Gemini parsing & sanitizing ---
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
    private static String enc(String s){
        if(s==null) return '';
        return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;').replace('\'','&#39;');
    }
}