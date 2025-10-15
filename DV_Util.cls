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

    // ---- CRITICAL: Clean string for JSON - removes ALL control characters ----
    public static String cleanStringForJson(String input) {
        if (String.isBlank(input)) return input;
        
        // Replace ALL control characters (ASCII 0-31) with spaces
        // This includes newlines, tabs, carriage returns, etc.
        String cleaned = input;
        
        for (Integer i = 0; i <= 31; i++) {
            String controlChar = String.fromCharArray(new List<Integer>{i});
            cleaned = cleaned.replace(controlChar, ' ');
        }
        
        // Also explicitly handle common ones
        cleaned = cleaned.replace('\n', ' ');
        cleaned = cleaned.replace('\r', ' ');
        cleaned = cleaned.replace('\t', ' ');
        
        return cleaned;
    }

    // ---- Project interesting fields ----------------------------------------
    public static Map<String,Object> projectInteresting(SObject rec) {
        String api = rec.getSObjectType().getDescribe().getName();
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();
        Map<String,Object> m = new Map<String,Object>();

        // CRITICAL: Put simple fields with cleaning
        putClean(rec, f, m, 'Name');
        putClean(rec, f, m, 'UniqueName');
        putClean(rec, f, m, 'DeveloperName');
        putClean(rec, f, m, 'ApiName');
        putClean(rec, f, m, 'OmniUiCardKey');
        putClean(rec, f, m, 'OmniProcessKey');
        putClean(rec, f, m, 'OmniUiCardType');
        putClean(rec, f, m, 'OmniProcessType');
        putClean(rec, f, m, 'Type');
        putClean(rec, f, m, 'SubType');
        
        // Boolean fields - no cleaning needed
        if (f.containsKey('IsActive') && rec.get('IsActive') != null) m.put('IsActive', rec.get('IsActive'));
        if (f.containsKey('Active') && rec.get('Active') != null) m.put('Active', rec.get('Active'));
        
        // Numeric fields - no cleaning needed
        if (f.containsKey('VersionNumber') && rec.get('VersionNumber') != null) m.put('VersionNumber', rec.get('VersionNumber'));
        if (f.containsKey('OmniScriptVersionNumber') && rec.get('OmniScriptVersionNumber') != null) m.put('OmniScriptVersionNumber', rec.get('OmniScriptVersionNumber'));
        if (f.containsKey('OmniProcessVersionNumber') && rec.get('OmniProcessVersionNumber') != null) m.put('OmniProcessVersionNumber', rec.get('OmniProcessVersionNumber'));
        
        putClean(rec, f, m, 'Language');

        // Complex fields that need special handling
        if (api == 'OmniUiCard') {
            putComplexClean(rec, f, m, 'PropertySetConfig', PROPERTY_CONFIG_MAX);
            putComplexClean(rec, f, m, 'DataSourceConfig', DATA_SOURCE_MAX);
            putComplexClean(rec, f, m, 'StylingConfiguration', STYLING_MAX);
            putComplexClean(rec, f, m, 'SampleDataSourceResponse', SAMPLE_DATA_MAX);
        } else if (api == 'OmniProcess') {
            putComplexClean(rec, f, m, 'IntegrationProcedureInput', 60000);
            putComplexClean(rec, f, m, 'IntegrationProcedureOutput', 60000);
            putComplexClean(rec, f, m, 'CustomJavaScript', 60000);
            putComplexClean(rec, f, m, 'CustomHtmlTemplates', 60000);
        } else if (api == 'OmniProcessElement') {
            putClean(rec, f, m, 'ParentElementName');
            putClean(rec, f, m, 'Type');
            if (f.containsKey('SequenceNumber') && rec.get('SequenceNumber') != null) m.put('SequenceNumber', rec.get('SequenceNumber'));
            if (f.containsKey('Level') && rec.get('Level') != null) m.put('Level', rec.get('Level'));
            putComplexClean(rec, f, m, 'PropertySetConfig', 60000);
        } else if (api == 'OmniDataTransform') {
            putClean(rec, f, m, 'Type');
            putClean(rec, f, m, 'GlobalKey');
            putComplexClean(rec, f, m, 'ExpectedInputJson', 90000);
            putComplexClean(rec, f, m, 'ExpectedOutputJson', 90000);
        } else if (api == 'OmniDataTransformItem') {
            putClean(rec, f, m, 'FormulaExpression');
            putClean(rec, f, m, 'FormulaResultPath');
            putClean(rec, f, m, 'OutputObjectName');
            putClean(rec, f, m, 'OutputFieldName');
            putClean(rec, f, m, 'InputObjectName');
            putClean(rec, f, m, 'InputFieldName');
            putClean(rec, f, m, 'LookupObjectName');
            putClean(rec, f, m, 'LookupByFieldName');
            putClean(rec, f, m, 'LookupReturnedFieldName');
            if (f.containsKey('FilterGroup') && rec.get('FilterGroup') != null) m.put('FilterGroup', rec.get('FilterGroup'));
            putClean(rec, f, m, 'FilterOperator');
            if (f.containsKey('IsDisabled') && rec.get('IsDisabled') != null) m.put('IsDisabled', rec.get('IsDisabled'));
            if (f.containsKey('IsRequired') && rec.get('IsRequired') != null) m.put('IsRequired', rec.get('IsRequired'));
            putClean(rec, f, m, 'GlobalKey');
            putComplexClean(rec, f, m, 'DefaultValue', 20000);
            putComplexClean(rec, f, m, 'TransformValueDefaultValue', 20000);
            putComplexClean(rec, f, m, 'TransformValueFormulaExpression', 20000);
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

    // Simple field - clean and put
    private static void putClean(SObject rec, Map<String,Schema.SObjectField> f, Map<String,Object> out, String field) {
        if (f.containsKey(field) && rec.get(field) != null) {
            String val = String.valueOf(rec.get(field));
            out.put(field, cleanStringForJson(val));
        }
    }
    
    // Complex field - clean, truncate if needed, put as-is (don't try to parse as JSON)
    private static void putComplexClean(SObject rec, Map<String,Schema.SObjectField> f, Map<String,Object> out, String field, Integer maxLen) {
        if (f.containsKey(field) && rec.get(field) != null) {
            String val = String.valueOf(rec.get(field));
            
            // Clean ALL control characters
            val = cleanStringForJson(val);
            
            // Truncate if too long
            if (maxLen != null && val.length() > maxLen) {
                val = val.substring(0, maxLen) + '\n... [TRUNCATED - ' + val.length() + ' chars total]';
            }
            
            // Put as-is - don't try to parse/format
            out.put(field, val);
        }
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