public with sharing class DV_AINotesUtil {

    // REPLACE WITH YOUR ACTUAL GEMINI API KEY
    private static final String GEMINI_API_KEY = 'AIzaSyB2AWIUftI0djCtlGC31xB_P3ACgSN8wO4';
    private static final String GEMINI_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent';

    // CRITICAL: Different handling for FlexCard vs OmniScript/DataRaptor
    public static String aiNotes(String componentName, String diff, String rawJson, String elementChangesSummary) {
        // Check if this is a FlexCard (PropertySetConfig modification)
        Boolean isFlexCard = (elementChangesSummary != null && 
                              elementChangesSummary.contains('PropertySetConfig'));
        
        if (isFlexCard) {
            return generateFlexCardNotes(componentName, elementChangesSummary);
        } else {
            return generateElementNotes(componentName, elementChangesSummary);
        }
    }

    // ==================== FLEXCARD NOTES ====================
    private static String generateFlexCardNotes(String componentName, String elementChangesSummary) {
        // If no changes
        if (String.isBlank(elementChangesSummary) || elementChangesSummary.contains('NO CHANGES')) {
            return buildNoChangesHtml();
        }
        
        // Extract character count if available
        String charInfo = '';
        if (elementChangesSummary.contains('chars changed')) {
            Integer startIdx = elementChangesSummary.indexOf('(');
            Integer endIdx = elementChangesSummary.indexOf('chars changed');
            if (startIdx > -1 && endIdx > -1) {
                charInfo = elementChangesSummary.substring(startIdx + 1, endIdx).trim();
            }
        }
        
        String prompt =
            'You are analyzing a Salesforce FlexCard UI configuration change. The PropertySetConfig (which contains the card\'s layout, styling, and data mapping) has been modified.\n\n' +
            
            '=== YOUR TASK ===\n' +
            'Create a concise 3-card summary explaining:\n' +
            '1. What type of UI changes likely occurred\n' +
            '2. Potential risks from configuration changes\n' +
            '3. What to test\n\n' +
            
            '=== OUTPUT FORMAT ===\n' +
            'Return ONLY this exact HTML structure:\n\n' +
            
            '<div class="highlight-card">\n' +
            '  <div class="card-title">🎯 Key Changes</div>\n' +
            '  <ul>\n' +
            '    <li>FlexCard UI configuration updated</li>\n' +
            '    <li>Possible layout or styling modifications</li>\n' +
            '    <li>Data mapping may have changed</li>\n' +
            '  </ul>\n' +
            '</div>\n' +
            '<div class="highlight-card warning">\n' +
            '  <div class="card-title">⚠️ Risks</div>\n' +
            '  <ul>\n' +
            '    <li>Card display may break on certain pages</li>\n' +
            '    <li>Data fields might not populate correctly</li>\n' +
            '  </ul>\n' +
            '</div>\n' +
            '<div class="highlight-card success">\n' +
            '  <div class="card-title">✅ Test This</div>\n' +
            '  <ul>\n' +
            '    <li>View card on all pages where embedded</li>\n' +
            '    <li>Verify all data fields display correctly</li>\n' +
            '  </ul>\n' +
            '</div>\n\n' +
            
            '=== RULES ===\n' +
            '- Each bullet point MAX 10 words\n' +
            '- Be specific but concise\n' +
            '- Focus on UI/layout/data mapping changes\n' +
            '- NO generic statements\n\n' +
            
            'Component: ' + componentName + '\n' +
            'Change: PropertySetConfig modified' + 
            (String.isBlank(charInfo) ? '' : ' (' + charInfo + ' characters changed)');

        String html = callGemini(prompt);
        
        if (!String.isBlank(html)) return html;

        // Fallback for FlexCard
        return buildFlexCardFallback(componentName, charInfo);
    }

    private static String buildFlexCardFallback(String componentName, String charInfo) {
        String charDetail = String.isBlank(charInfo) ? '' : ' (' + charInfo + ' chars)';
        
        return '<div class="highlight-card">' +
               '<div class="card-title">🎯 Key Changes</div>' +
               '<ul>' +
               '<li>FlexCard UI configuration updated' + charDetail + '</li>' +
               '<li>PropertySetConfig modified - layout or styling changed</li>' +
               '<li>Review Raw tab for detailed changes</li>' +
               '</ul>' +
               '</div>' +
               '<div class="highlight-card warning">' +
               '<div class="card-title">⚠️ Risks</div>' +
               '<ul>' +
               '<li>Card display may differ on pages</li>' +
               '<li>Data binding might be affected</li>' +
               '</ul>' +
               '</div>' +
               '<div class="highlight-card success">' +
               '<div class="card-title">✅ Test This</div>' +
               '<ul>' +
               '<li>Test card on all embedded pages</li>' +
               '<li>Verify all fields populate correctly</li>' +
               '</ul>' +
               '</div>';
    }

    // ==================== ELEMENT NOTES (OmniScript/DataRaptor) ====================
    private static String generateElementNotes(String componentName, String elementChangesSummary) {
        // If no element changes
        if (String.isBlank(elementChangesSummary) || elementChangesSummary.contains('NO CHANGES')) {
            return buildNoChangesHtml();
        }
        
        // Extract ONLY additions and deletions
        String onlyAdditionsAndDeletions = extractAdditionsAndDeletions(elementChangesSummary);
        
        // If no additions or deletions, return simple message
        if (String.isBlank(onlyAdditionsAndDeletions) || 
            (!onlyAdditionsAndDeletions.contains('=== ADDED') && 
             !onlyAdditionsAndDeletions.contains('=== REMOVED'))) {
            return buildNoChangesHtml();
        }
        
        String prompt =
            'You are analyzing OmniStudio component changes. Your task is to summarize ONLY the elements that were ADDED or REMOVED. COMPLETELY IGNORE any modified elements.\n\n' +
            
            '=== CRITICAL RULES ===\n' +
            '1. ONLY mention elements from the "ADDED" section (marked with +)\n' +
            '2. ONLY mention elements from the "REMOVED" section (marked with -)\n' +
            '3. COMPLETELY IGNORE the "MODIFIED" section (marked with ~)\n' +
            '4. If an element appears in MODIFIED but not in ADDED or REMOVED, DO NOT mention it at all\n' +
            '5. Each bullet point must be MAX 10 words\n' +
            '6. Use specific element names from the data below\n\n' +
            
            '=== OUTPUT FORMAT ===\n' +
            'Return ONLY this exact HTML structure with NO additional text:\n\n' +
            
            '<div class="highlight-card">\n' +
            '  <div class="card-title">🎯 Key Changes</div>\n' +
            '  <ul>\n' +
            '    <li>Added [element name] to [parent]</li>\n' +
            '    <li>Removed [element name] from [parent]</li>\n' +
            '  </ul>\n' +
            '</div>\n' +
            '<div class="highlight-card warning">\n' +
            '  <div class="card-title">⚠️ Risks</div>\n' +
            '  <ul><li>Specific risk related to the changes</li></ul>\n' +
            '</div>\n' +
            '<div class="highlight-card success">\n' +
            '  <div class="card-title">✅ Test This</div>\n' +
            '  <ul><li>Specific test scenario</li></ul>\n' +
            '</div>\n\n' +
            
            '=== EXAMPLE ===\n' +
            'If the data shows:\n' +
            '=== ADDED (2) ===\n' +
            '+ EmailField (Email) under Step2\n' +
            '+ SaveButton (Button) under Step3\n' +
            '=== REMOVED (1) ===\n' +
            '- OldField (Text) from Step1\n' +
            '=== MODIFIED (10) ===\n' +
            '~ Step1 configuration changed\n' +
            '~ Step2 styling updated\n' +
            '...(more modified items)\n\n' +
            
            'YOU SHOULD OUTPUT:\n' +
            '<div class="highlight-card">\n' +
            '  <div class="card-title">🎯 Key Changes</div>\n' +
            '  <ul>\n' +
            '    <li>Added EmailField to Step2</li>\n' +
            '    <li>Added SaveButton to Step3</li>\n' +
            '    <li>Removed OldField from Step1</li>\n' +
            '  </ul>\n' +
            '</div>\n' +
            '<div class="highlight-card warning">\n' +
            '  <div class="card-title">⚠️ Risks</div>\n' +
            '  <ul><li>Test email validation rules thoroughly</li></ul>\n' +
            '</div>\n' +
            '<div class="highlight-card success">\n' +
            '  <div class="card-title">✅ Test This</div>\n' +
            '  <ul><li>Verify EmailField captures user input correctly</li></ul>\n' +
            '</div>\n\n' +
            
            'Component: ' + componentName + '\n\n' +
            '=== ELEMENT CHANGES (FOCUS HERE) ===\n' + onlyAdditionsAndDeletions;

        String html = callGemini(prompt);
        
        if (!String.isBlank(html)) return html;

        // Fallback: Build from element summary
        return buildElementFallback(elementChangesSummary);
    }

    // ==================== SHARED UTILITIES ====================
    
    private static String buildNoChangesHtml() {
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
    
    private static String extractAdditionsAndDeletions(String elementSummary) {
        if (String.isBlank(elementSummary)) return '';
        
        List<String> lines = splitLines(elementSummary);
        List<String> result = new List<String>();
        
        Boolean inAddedSection = false;
        Boolean inRemovedSection = false;
        Boolean inModifiedSection = false;
        
        for (String line : lines) {
            if (line.contains('=== ADDED')) {
                inAddedSection = true;
                inRemovedSection = false;
                inModifiedSection = false;
                result.add(line);
            } else if (line.contains('=== REMOVED')) {
                inAddedSection = false;
                inRemovedSection = true;
                inModifiedSection = false;
                result.add(line);
            } else if (line.contains('=== MODIFIED')) {
                inAddedSection = false;
                inRemovedSection = false;
                inModifiedSection = true;
                // DON'T add modified section to result
            } else if (line.startsWith('+ ') && inAddedSection) {
                result.add(line);
            } else if (line.startsWith('- ') && inRemovedSection) {
                result.add(line);
            } else if (line.startsWith('  Details:') && (inAddedSection || inRemovedSection)) {
                result.add(line);
            }
            // SKIP everything in modified section
        }
        
        return String.join(result, '\n');
    }

    private static String buildElementFallback(String elementSummary) {
        List<String> lines = splitLines(elementSummary);
        List<String> added = new List<String>();
        List<String> removed = new List<String>();
        
        for (String line : lines) {
            if (line.startsWith('+ ')) {
                String content = line.substring(2).trim();
                if (content.length() > 80) content = content.substring(0, 77) + '...';
                added.add(content);
            } else if (line.startsWith('- ')) {
                String content = line.substring(2).trim();
                if (content.length() > 80) content = content.substring(0, 77) + '...';
                removed.add(content);
            }
            // SKIP modified elements (lines starting with '~')
        }
        
        // Build Key Changes card
        String keyChangesHtml = '<div class="highlight-card"><div class="card-title">🎯 Key Changes</div><ul>';
        
        Integer totalChanges = added.size() + removed.size();
        if (totalChanges == 0) {
            keyChangesHtml += '<li>No element additions or deletions detected</li>';
        } else {
            Integer itemsShown = 0;
            
            for (String item : added) {
                if (itemsShown >= 5) break;
                keyChangesHtml += '<li>Added: ' + escapeHtml(item) + '</li>';
                itemsShown++;
            }
            
            for (String item : removed) {
                if (itemsShown >= 5) break;
                keyChangesHtml += '<li>Removed: ' + escapeHtml(item) + '</li>';
                itemsShown++;
            }
            
            if (totalChanges > 5) {
                keyChangesHtml += '<li>' + (totalChanges - 5) + ' more changes</li>';
            }
        }
        keyChangesHtml += '</ul></div>';
        
        // Build Risks card
        String risksHtml = '<div class="highlight-card warning"><div class="card-title">⚠️ Risks</div><ul>';
        if (removed.size() > 0) {
            risksHtml += '<li>Removed elements may break dependent flows</li>';
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
        } else {
            testHtml += '<li>Run full regression test suite</li>';
        }
        testHtml += '</ul></div>';
        
        return keyChangesHtml + risksHtml + testHtml;
    }
    
    // ==================== GEMINI API CALL ====================
    
    private static String callGemini(String prompt) {
        try {
            HttpRequest req = new HttpRequest();
            req.setMethod('POST'); 
            req.setEndpoint(GEMINI_ENDPOINT + '?key=' + GEMINI_API_KEY);
            req.setHeader('Content-Type','application/json'); 
            req.setTimeout(120000);
            
            Map<String,Object> payload = new Map<String,Object>{
                'contents' => new List<Object>{
                    new Map<String,Object>{
                        'parts' => new List<Object>{ new Map<String,Object>{ 'text' => prompt } }
                    }
                }
            };
            
            req.setBody(JSON.serialize(payload));
            Http http = new Http(); 
            HttpResponse res = http.send(req);
            
            System.debug('Gemini API Status Code: ' + res.getStatusCode());
            
            if (res.getStatusCode() == 200) {
                String parsed = parseGeminiHtml(res.getBody());
                if (!String.isBlank(parsed)) return cleanForUi(parsed);
            } else {
                System.debug('Gemini API Error: ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('AI Notes error: ' + e.getMessage());
        }
        
        return null;
    }
    
    private static String escapeHtml(String text) {
        if (String.isBlank(text)) return '';
        return text.replace('&', '&amp;')
                   .replace('<', '&lt;')
                   .replace('>', '&gt;')
                   .replace('"', '&quot;')
                   .replace('\'', '&#39;');
    }

    private static String parseGeminiHtml(String jsonResponse) {
        if (String.isBlank(jsonResponse)) return null;
        try {
            Map<String,Object> parsed = (Map<String,Object>) JSON.deserializeUntyped(jsonResponse);
            List<Object> cand = (List<Object>) parsed.get('candidates');
            if (cand == null || cand.isEmpty()) return null;
            Map<String,Object> first = (Map<String,Object>) cand[0];
            Map<String,Object> content = (Map<String,Object>) first.get('content');
            if (content == null) return null;
            List<Object> parts = (List<Object>) content.get('parts');
            if (parts == null || parts.isEmpty()) return null;
            Map<String,Object> firstPart = (Map<String,Object>) parts[0];
            Object text = firstPart.get('text');
            return (text == null) ? null : String.valueOf(text);
        } catch (Exception e) { 
            System.debug('Error parsing Gemini response: ' + e.getMessage());
            return null; 
        }
    }
    
    public static String cleanForUi(String html) {
        if (String.isBlank(html)) return '';
        String out = html.replace('```html','').replace('```','');
        out = out.replaceAll('(?is)<script[\\s\\S]*?</script>','');
        out = out.replaceAll('(?is)<style[\\s\\S]*?</style>','');
        out = out.replaceAll('`{1,3}','');
        return out;
    }
    
    private static List<String> splitLines(String s) {
        if (s == null) return new List<String>();
        String norm = s.replace('\r\n','\n');
        return new List<String>(norm.split('\n', -1));
    }
    
    public static String unifiedDiff(String oldText, String newText) {
        if (String.isBlank(oldText)) oldText = '';
        if (String.isBlank(newText)) newText = '';
        
        List<String> oldLines = splitLines(oldText);
        List<String> newLines = splitLines(newText);
        
        List<String> result = new List<String>();
        result.add('--- OLD');
        result.add('+++ NEW');
        
        Integer i = 0, j = 0;
        while (i < oldLines.size() || j < newLines.size()) {
            if (i < oldLines.size() && j < newLines.size() && oldLines[i] == newLines[j]) {
                result.add(' ' + oldLines[i]);
                i++; j++;
            } else if (i < oldLines.size() && (j >= newLines.size() || oldLines[i] != newLines[j])) {
                result.add('- ' + oldLines[i]);
                i++;
            } else if (j < newLines.size()) {
                result.add('+ ' + newLines[j]);
                j++;
            }
        }
        
        return String.join(result, '\n');
    }
}