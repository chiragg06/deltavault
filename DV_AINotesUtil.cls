public with sharing class DV_AINotesUtil {

    // CRITICAL: Element-focused AI Notes generation
    public static String aiNotes(String componentName, String diff, String rawJson, String elementChangesSummary) {
        // CRITICAL: If no element changes, use fallback immediately
        if (String.isBlank(elementChangesSummary) || elementChangesSummary.contains('NO CHANGES')) {
            return '<div class="highlight-card">' +
                   '<div class="card-title">🎯 Key Changes</div>' +
                   '<ul><li>No element-level changes detected</li></ul>' +
                   '</div>' +
                   '<div class="highlight-card warning">' +
                   '<div class="card-title">⚠️ Risks</div>' +
                   '<ul><li>Review configuration changes in other tabs</li></ul>' +
                   '</div>' +
                   '<div class="highlight-card success">' +
                   '<div class="card-title">✅ Test This</div>' +
                   '<ul><li>Verify component functionality is unchanged</li></ul>' +
                   '</div>';
        }
        
        // Build context from element changes summary
        String elementContext = '\n\n=== ELEMENT CHANGES (Primary Focus) ===\n' + elementChangesSummary;
        
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
            '• NO explanatory text outside cards\n\n' +
            'Component: ' + componentName + elementContext;

        String endpoint = 'callout:Gemini_API/v1beta/models/gemini-2.0-flash-exp:generateContent';
        
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
            req.setMethod('POST'); 
            req.setEndpoint(endpoint);
            req.setHeader('Content-Type','application/json'); 
            req.setTimeout(120000);
            req.setBody(JSON.serialize(payload));
            Http http = new Http(); 
            HttpResponse res = http.send(req);
            if(res.getStatusCode()==200){
                String parsed = parseGeminiHtml(res.getBody());
                if(!String.isBlank(parsed)) html = cleanForUi(parsed);
            }
        } catch(Exception e){
            System.debug('AI Notes error: ' + e.getMessage());
        }

        if(!String.isBlank(html)) return html;

        // FALLBACK: Parse element changes summary directly
        return buildFallbackHtmlFromElementSummary(elementChangesSummary);
    }

    // CRITICAL: Build concise fallback summaries from ElementChangesSummary
    private static String buildFallbackHtmlFromElementSummary(String elementSummary) {
        List<String> lines = splitLines(elementSummary);
        List<String> added = new List<String>();
        List<String> removed = new List<String>();
        List<String> modified = new List<String>();
        
        for (String line : lines) {
            if (line.startsWith('+ ')) {
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
    
    private static List<String> splitLines(String s){
        if(s==null) return new List<String>();
        String norm = s.replace('\r\n','\n');
        return new List<String>(norm.split('\n', -1));
    }
    
    // CRITICAL: No more deepDiff - we compare elements directly
    public static String deepDiff(String oldJson, String newJson) {
        // Deprecated - not used anymore
        return '';
    }
}