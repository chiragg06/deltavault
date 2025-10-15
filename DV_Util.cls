public with sharing class DV_Util {

    private static final Integer PROPERTY_CONFIG_MAX = 100000;
    private static final Integer DATA_SOURCE_MAX = 100000;
    private static final Integer STYLING_MAX = 100000;
    private static final Integer SAMPLE_DATA_MAX = 50000;

    // ---- Type mapping -------------------------------------------------------
    public static DV_Constants.CompType mapType(SObject rec) {
        String api = rec.getSObjectType().getDescribe().getName();
        if (api == 'OmniUiCard')             return DV_Constants.CompType.Flexcard;
        if (api == 'OmniProcess')            return DV_Constants.CompType.OmniProcess;
        if (api == 'OmniProcessElement')     return DV_Constants.CompType.OmniProcessElement;
        if (api == 'OmniProcessCompilation') return DV_Constants.CompType.OmniProcessCompilation;
        if (api == 'OmniDataTransform')      return DV_Constants.CompType.DataMapper;
        if (api == 'OmniDataTransformItem')  return DV_Constants.CompType.DataMapperItem;
        return DV_Constants.CompType.Unknown;
    }

    // ---- Full name (human) --------------------------------------------------
    public static String deriveFullName(SObject rec, DV_Constants.CompType t) {
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();

        String base = pickFirst(rec, f, new List<String>{
            'UniqueName','DeveloperName','ApiName','OmniUiCardKey','OmniProcessKey','Name'
        });
        if (String.isBlank(base)) base = String.valueOf(rec.get('Id'));

        String type  = f.containsKey('Type')    && rec.get('Type')    != null ? String.valueOf(rec.get('Type'))    : null;
        String sub   = f.containsKey('SubType') && rec.get('SubType') != null ? String.valueOf(rec.get('SubType')) : null;

        String typeSub = null;
        if (!String.isBlank(type)) typeSub = type;
        if (!String.isBlank(sub))  typeSub = (typeSub==null? '' : typeSub + '/') + sub;

        Decimal ver = sniffVersion(rec);
        String name = base;
        if (!String.isBlank(typeSub)) name += ' • ' + typeSub;
        if (t == DV_Constants.CompType.OmniProcess && ver != null) name += ' v' + String.valueOf(ver);
        return name;
    }
    
    private static String pickFirst(SObject rec, Map<String, Schema.SObjectField> f, List<String> keys) {
        for (String k : keys) if (f.containsKey(k) && rec.get(k) != null) return String.valueOf(rec.get(k));
        return null;
    }

    public static String stripVersion(String full) {
        return full != null ? full : '';
    }

    // ADDED: Recursively sanitize Map/List structures before JSON serialization
    public static Object sanitizeForJsonSerialization(Object obj) {
        if (obj == null) return null;
        
        if (obj instanceof String) {
            String str = (String)obj;
            
            // Replace control characters with spaces or remove them
            // JSON.serialize() will handle the actual escaping, we just need to remove illegal chars
            str = str.replace('\u0000', ''); // null
            str = str.replace('\u0001', ''); 
            str = str.replace('\u0002', '');
            str = str.replace('\u0003', '');
            str = str.replace('\u0004', '');
            str = str.replace('\u0005', '');
            str = str.replace('\u0006', '');
            str = str.replace('\u0007', '');
            str = str.replace('\u0008', ''); // backspace
            // Keep \u0009 (tab), \u000A (newline), \u000D (carriage return) - JSON.serialize handles these
            str = str.replace('\u000B', ''); // vertical tab
            str = str.replace('\u000C', ''); // form feed
            str = str.replace('\u000E', '');
            str = str.replace('\u000F', '');
            str = str.replace('\u0010', '');
            str = str.replace('\u0011', '');
            str = str.replace('\u0012', '');
            str = str.replace('\u0013', '');
            str = str.replace('\u0014', '');
            str = str.replace('\u0015', '');
            str = str.replace('\u0016', '');
            str = str.replace('\u0017', '');
            str = str.replace('\u0018', '');
            str = str.replace('\u0019', '');
            str = str.replace('\u001A', '');
            str = str.replace('\u001B', ''); // escape
            str = str.replace('\u001C', '');
            str = str.replace('\u001D', '');
            str = str.replace('\u001E', '');
            str = str.replace('\u001F', '');
            
            return str;
        }
        
        if (obj instanceof Map<String,Object>) {
            Map<String,Object> inputMap = (Map<String,Object>)obj;
            Map<String,Object> cleaned = new Map<String,Object>();
            for (String key : inputMap.keySet()) {
                cleaned.put(key, sanitizeForJsonSerialization(inputMap.get(key)));
            }
            return cleaned;
        }
        
        if (obj instanceof List<Object>) {
            List<Object> inputList = (List<Object>)obj;
            List<Object> cleaned = new List<Object>();
            for (Object item : inputList) {
                cleaned.add(sanitizeForJsonSerialization(item));
            }
            return cleaned;
        }
        
        // For primitives (Integer, Boolean, Decimal, etc.), return as-is
        return obj;
    }

    // ADDED: Sanitize control characters that break JSON
    private static String sanitizeForJson(String str) {
        if (String.isBlank(str)) return str;
        
        // Remove problematic control characters (ASCII 0-31 except \t, \n, \r)
        return str
            .replace('\u0000', '') .replace('\u0001', '') .replace('\u0002', '')
            .replace('\u0003', '') .replace('\u0004', '') .replace('\u0005', '')
            .replace('\u0006', '') .replace('\u0007', '') .replace('\u0008', '')
            // Keep \u0009 (tab), \u000A (newline), \u000D (carriage return)
            .replace('\u000B', '') .replace('\u000C', '')
            .replace('\u000E', '') .replace('\u000F', '') .replace('\u0010', '')
            .replace('\u0011', '') .replace('\u0012', '') .replace('\u0013', '')
            .replace('\u0014', '') .replace('\u0015', '') .replace('\u0016', '')
            .replace('\u0017', '') .replace('\u0018', '') .replace('\u0019', '')
            .replace('\u001A', '') .replace('\u001B', '') .replace('\u001C', '')
            .replace('\u001D', '') .replace('\u001E', '') .replace('\u001F', '');
    }

    public static String normalizeJson(String maybeJson, Integer max) {
        if (String.isBlank(maybeJson)) return null;
        
        maybeJson = sanitizeForJson(maybeJson);
        
        try {
            Object u = JSON.deserializeUntyped(maybeJson);
            Object sorted = sortJson(u);
            String pretty = JSON.serializePretty(sorted);
            
            pretty = sanitizeForJson(pretty);
            
            if (max != null && pretty.length() > max) {
                return pretty.substring(0, max) + '\n... [TRUNCATED - ' + pretty.length() + ' chars total]';
            }
            return pretty;
        } catch (Exception ex) {
            if (max != null && maybeJson.length() > max) {
                return maybeJson.substring(0, max) + '\n... [TRUNCATED - ' + maybeJson.length() + ' chars total]';
            }
            return maybeJson;
        }
    }
    
    private static Object sortJson(Object val) {
        if (val instanceof Map<String,Object>) {
            Map<String,Object> mapVal = (Map<String,Object>)val;
            List<String> ks = new List<String>(mapVal.keySet()); 
            ks.sort();
            Map<String,Object> out = new Map<String,Object>();
            for (String k : ks) out.put(k, sortJson(mapVal.get(k)));
            return out;
        } else if (val instanceof List<Object>) {
            List<Object> listVal = (List<Object>)val;
            List<Object> out = new List<Object>();
            for (Object o : listVal) out.add(sortJson(o));
            return out;
        }
        return val;
    }

    // ---- Project interesting fields ----------------------------------------
    public static Map<String,Object> projectInteresting(SObject rec) {
        String api = rec.getSObjectType().getDescribe().getName();
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();
        Map<String,Object> m = new Map<String,Object>();

        putIfPresent(rec,f,m,'Name'); putIfPresent(rec,f,m,'UniqueName'); putIfPresent(rec,f,m,'DeveloperName');
        putIfPresent(rec,f,m,'ApiName'); putIfPresent(rec,f,m,'OmniUiCardKey'); putIfPresent(rec,f,m,'OmniProcessKey');
        putIfPresent(rec,f,m,'OmniUiCardType'); putIfPresent(rec,f,m,'OmniProcessType');
        putIfPresent(rec,f,m,'Type'); putIfPresent(rec,f,m,'SubType');
        putIfPresent(rec,f,m,'IsActive'); putIfPresent(rec,f,m,'Active');
        putIfPresent(rec,f,m,'VersionNumber'); putIfPresent(rec,f,m,'OmniScriptVersionNumber'); putIfPresent(rec,f,m,'OmniProcessVersionNumber');
        putIfPresent(rec,f,m,'Language');

        if (api == 'OmniUiCard') {
            normIfPresent(rec,f,m,'PropertySetConfig', PROPERTY_CONFIG_MAX);
            normIfPresent(rec,f,m,'DataSourceConfig', DATA_SOURCE_MAX);
            normIfPresent(rec,f,m,'StylingConfiguration', STYLING_MAX);
            normIfPresent(rec,f,m,'SampleDataSourceResponse', SAMPLE_DATA_MAX);
        } else if (api == 'OmniProcess') {
            normIfPresent(rec,f,m,'IntegrationProcedureInput',60000);
            normIfPresent(rec,f,m,'IntegrationProcedureOutput',60000);
            normIfPresent(rec,f,m,'CustomJavaScript',60000);
            normIfPresent(rec,f,m,'CustomHtmlTemplates',60000);
        } else if (api == 'OmniProcessElement') {
            putIfPresent(rec,f,m,'ParentElementName'); putIfPresent(rec,f,m,'Type');
            putIfPresent(rec,f,m,'SequenceNumber'); putIfPresent(rec,f,m,'Level');
            normIfPresent(rec,f,m,'PropertySetConfig',60000);
        } else if (api == 'OmniDataTransform') {
            putIfPresent(rec,f,m,'Type'); putIfPresent(rec,f,m,'GlobalKey');
            normIfPresent(rec,f,m,'ExpectedInputJson',90000);
            normIfPresent(rec,f,m,'ExpectedOutputJson',90000);
        } else if (api == 'OmniDataTransformItem') {
            putIfPresent(rec,f,m,'FormulaExpression'); 
            putIfPresent(rec,f,m,'FormulaResultPath');
            putIfPresent(rec,f,m,'OutputObjectName'); 
            putIfPresent(rec,f,m,'OutputFieldName');
            putIfPresent(rec,f,m,'InputObjectName');  
            putIfPresent(rec,f,m,'InputFieldName');
            putIfPresent(rec,f,m,'LookupObjectName'); 
            putIfPresent(rec,f,m,'LookupByFieldName'); 
            putIfPresent(rec,f,m,'LookupReturnedFieldName');
            putIfPresent(rec,f,m,'FilterGroup');
            putIfPresent(rec,f,m,'FilterOperator');
            putIfPresent(rec,f,m,'IsDisabled');
            putIfPresent(rec,f,m,'IsRequired');
            putIfPresent(rec,f,m,'GlobalKey');
            normIfPresent(rec,f,m,'DefaultValue',20000);
            normIfPresent(rec,f,m,'InputFieldName',20000);
            normIfPresent(rec,f,m,'TransformValueDefaultValue',20000);
            normIfPresent(rec,f,m,'TransformValueFormulaExpression',20000);
        }
        return m;
    }

    public static Decimal sniffVersion(SObject rec) {
        if (rec == null) return null;
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();
        Object v = null;
        if (f.containsKey('VersionNumber')) v = rec.get('VersionNumber');
        else if (f.containsKey('OmniScriptVersionNumber')) v = rec.get('OmniScriptVersionNumber');
        else if (f.containsKey('OmniProcessVersionNumber')) v = rec.get('OmniProcessVersionNumber');
        return toDecimalSafe(v);
    }
    
    public static Decimal sniffVersion(Map<String,Object> m) {
        if (m == null) return null;
        Object v = null;
        if (m.containsKey('VersionNumber')) v = m.get('VersionNumber');
        else if (m.containsKey('OmniScriptVersionNumber')) v = m.get('OmniScriptVersionNumber');
        else if (m.containsKey('OmniProcessVersionNumber')) v = m.get('OmniProcessVersionNumber');
        return toDecimalSafe(v);
    }
    
    private static Decimal toDecimalSafe(Object v) {
        if (v == null) return null;
        try { return (v instanceof Decimal) ? (Decimal)v : Decimal.valueOf(String.valueOf(v)); }
        catch (Exception e) { return null; }
    }

    private static void putIfPresent(SObject rec, Map<String,Schema.SObjectField> f, Map<String,Object> out, String field){
        if (f.containsKey(field)) out.put(field, rec.get(field));
    }
    
    private static void normIfPresent(SObject rec, Map<String,Schema.SObjectField> f, Map<String,Object> out, String field, Integer max){
        if (f.containsKey(field) && rec.get(field) != null) {
            String rawValue = String.valueOf(rec.get(field));
            // CRITICAL: Remove control characters BEFORE normalizing JSON
            rawValue = sanitizeStringValue(rawValue);
            out.put(field, normalizeJson(rawValue, max));
        }
    }
    
    // Remove control characters from string values
    private static String sanitizeStringValue(String str) {
        if (String.isBlank(str)) return str;
        
        // Remove control characters that break JSON parsing
        return str
            .replace('\u0000', '') .replace('\u0001', '') .replace('\u0002', '')
            .replace('\u0003', '') .replace('\u0004', '') .replace('\u0005', '')
            .replace('\u0006', '') .replace('\u0007', '') .replace('\u0008', '')
            // Keep tab, newline, carriage return - they're valid in JSON strings
            .replace('\u000B', '') .replace('\u000C', '')
            .replace('\u000E', '') .replace('\u000F', '') .replace('\u0010', '')
            .replace('\u0011', '') .replace('\u0012', '') .replace('\u0013', '')
            .replace('\u0014', '') .replace('\u0015', '') .replace('\u0016', '')
            .replace('\u0017', '') .replace('\u0018', '') .replace('\u0019', '')
            .replace('\u001A', '') .replace('\u001B', '') .replace('\u001C', '')
            .replace('\u001D', '') .replace('\u001E', '') .replace('\u001F', '');
    }

    // ---- Describe-aware field list -----------------------------------------
    public static String fieldListFor(String apiName) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(apiName);
        if (t == null) return 'Id, LastModifiedDate';
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();

        List<String> order = new List<String>();
        if (fmap.containsKey('Id'))               order.add('Id');
        if (fmap.containsKey('LastModifiedDate')) order.add('LastModifiedDate');

        List<String> wanted = new List<String>{
            'Name','UniqueName','DeveloperName','ApiName',
            'OmniUiCardKey','OmniProcessKey','OmniUiCardType','OmniProcessType',
            'Type','SubType','IsActive','Active',
            'VersionNumber','OmniScriptVersionNumber','OmniProcessVersionNumber',
            'DataSourceConfig','StylingConfiguration','PropertySetConfig','SampleDataSourceResponse',
            'IntegrationProcedureInput','IntegrationProcedureOutput','CustomJavaScript','CustomHtmlTemplates','Language',
            'ExpectedInputJson','ExpectedOutputJson','InputType','OutputType','GlobalKey',
            'FormulaExpression','FormulaResultPath','DefaultValue','InputFieldName','ParentElementName','SequenceNumber','Level',
            'OmniProcessId','OmniDataTransformationId',
            'OutputObjectName','OutputFieldName','InputObjectName',
            'LookupObjectName','LookupByFieldName','LookupReturnedFieldName',
            'FilterGroup','FilterOperator','IsDisabled','IsRequired',
            'TransformValueDefaultValue','TransformValueFormulaExpression'
        };
        for (String f : wanted) if (fmap.containsKey(f) && order.indexOf(f) < 0) order.add(f);
        return String.join(order, ',');
    }
}