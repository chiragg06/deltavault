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

    // --- AI notes: OmniStudio ---
    public static String aiNotes(String componentName, String diff, String rawJson) {
        String prompt =
            'You are a senior Salesforce OmniStudio reviewer. Based on the DIFF and RAW JSON, ' +
            'produce concise release-notes style HTML for developers. ' +
            'Use only these tags: <p>, <ul>, <li>, <strong>, <code>. ' +
            'Sections: Summary, Impact, Risks, Test Ideas. Keep under 180 words.\n\n' +
            'Component: ' + componentName + '\n\n=== DIFF ===\n' + (diff==null?'':diff) +
            '\n\n=== RAW JSON (truncated) ===\n' + (rawJson==null?'':rawJson.left(8000));

        // NOTE: this uses the key you provided in your code; keep it as-is or move to Named Credential.
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
        } catch(Exception e){}

        String elemBullets = elementImpactBullets(diff);
        if(!String.isBlank(html)) return html + elemBullets;

        // fallback if callout fails
        Integer adds=0, dels=0;
        for(String line : splitLines(diff)){ if(line!=null && line.startsWith('+ ')) adds++; else if(line!=null && line.startsWith('- ')) dels++; }
        return '<p><strong>Summary:</strong> Updated <code>' + enc(componentName) + '</code> with ' + adds + ' additions and ' + dels + ' removals.</p>' +
               '<ul><li><strong>Impact:</strong> Behavior may change in affected branches.</li>' +
               '<li><strong>Risks:</strong> Data mapping / element flow regressions.</li>' +
               '<li><strong>Test Ideas:</strong> Validate inputs/outputs and branch paths.</li></ul>' + elemBullets;
    }

    private static String elementImpactBullets(String diff) {
        if (String.isBlank(diff)) return '';
        List<String> pts = new List<String>();
        for (String line : diff.split('\n')) {
            if (line == null) continue;
            Boolean interesting =
                line.startsWith('+ Added Elements[') || line.startsWith('~ Changed Elements[') || line.startsWith('- Removed Elements[') ||
                line.startsWith('+ Added childPayload') || line.startsWith('~ Changed childPayload') || line.startsWith('- Removed childPayload') ||
                line.contains('PropertySetConfig.elements[');
            if (interesting) {
                String s = line.replace('childPayload.', '');
                pts.add('<li>' + enc(s) + '</li>');
                if (pts.size() >= 10) break;
            }
        }
        return pts.isEmpty() ? '' : '<ul><li><strong>Element Impacts:</strong></li>' + String.join(pts, '') + '</ul>';
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
