# Mass Migrator Wizard - Transform Script Generator

**Command**: `mass-migrator wizard`
**Source**: `cmd/wizard/main.go`, `internal/generator/generator.go`

The wizard is an interactive CLI tool that helps you create transform scripts and pipeline configurations through a guided questionnaire. It bridges user intent → DSL AST → JavaScript code generation.

---

## Overview

The wizard walks you through a 5-step process:

1. **Input Fields** - Define source data fields (name, type)
2. **Output Fields** - Define target fields with DSL transformations
3. **Filter Condition** (optional) - Add record filtering logic
4. **Transform Mode** - Auto-detect or specify the transformation pattern
5. **Output Format** - Choose screen, file, or YAML output

---

## Core Data Structures

### FieldInfo

Describes an input field from the source data.

```go
type FieldInfo struct {
    Name string  // Field name as it appears in source data
    Type string  // One of: STRING, INTEGER, FLOAT, BOOLEAN, TIMESTAMP, DECIMAL
}
```

**Used in**:
- `WizardState.InputFields` - Wizard state tracking
- `generator.Options.InputFields` - Generator configuration

**Location**: `cmd/wizard/main.go` (wizard), `internal/generator/generator.go` (generator)

---

### TransformField

Represents an output field with its transformation logic.

```go
type TransformField struct {
    Name         string  // Output field name
    DSLExpression string  // DSL expression (e.g., "lower(trim(name))")
}
```

**Used in**:
- `WizardState.OutputFields` - Wizard state tracking

**Location**: `cmd/wizard/main.go`

---

### WizardState

Tracks the wizard's progress through the 5-step workflow.

```go
type WizardState struct {
    InputFields     []FieldInfo       // Step 1: Source fields
    OutputFields    []TransformField  // Step 2: Target fields + transformations
    FilterExpression string           // Step 3: Optional filter DSL
    TransformMode   string           // Step 4: one_to_one, one_to_many, many_to_one, many_to_many
    OutputFormat    string           // Step 5: screen, file, yaml
    OutputFile      string           // Output file path (if format=file/yaml)
}
```

**Workflow**:
```
promptInputFields() → promptOutputFields() → promptFilter() 
  → promptTransformMode() → promptOutputFormat() → generateAndOutput()
```

**Location**: `cmd/wizard/main.go`

---

## Transform Modes

The wizard auto-detects the transform mode by analyzing DSL expressions:

| Mode | Pattern | Description |
|------|----------|-------------|
| `one_to_one` | Single field, no array | 1 input → 1 output record |
| `one_to_many` | `.HasArrayReturn()` | 1 input → N output records (unnest) |
| `many_to_one` | `batch` identifier | N input → 1 output record (aggregate) |
| `many_to_many` | `records` identifier | N input → M output records (cross-product) |

**Detection logic** (`promptTransformMode`):
```go
for _, f := range state.OutputFields {
    ast, _ := dsl.ParseString(f.DSLExpression)
    if ast.HasArrayReturn() {
        detectedMode = "one_to_many"
    } else if ast.HasIdentifier("batch") {
        detectedMode = "many_to_one"
    } else if ast.HasIdentifier("records") {
        detectedMode = "many_to_many"
    }
}
```

---

## Code Generation Pipeline

```
User Input (WizardState)
    ↓
DSL Expression Parse → dsl.ParseString()
    ↓
AST Analysis → DetectMode(), InferHelpers()
    ↓
Code Generation → generator.Generate()
    ↓
Output → JavaScript file or YAML step config
```

### Generator Integration

The wizard calls `generator.Generate()` with:

```go
result, err := generator.Generate(ast, generator.Options{
    InputFields:  convertToGeneratorFieldInfo(state.InputFields),
    OutputFields: extractOutputFieldNames(state.OutputFields),
    Mode:         parseTransformMode(state.TransformMode),
})
```

**Returns** (`GenerateResult`):
```go
type GenerateResult struct {
    Code         string   // Generated JavaScript code
    Mode         TransformMode
    Helpers      []string // Required helper functions
    InputFields  []string
    OutputFields []string
    RequiredKeys []string // For MANY_TO_ONE mode
}
```

---

## Example Session

```
$ mass-migrator wizard

=== Step 1: Input Fields ===
Define the input fields available in your source data.

Field name: email
Field type: STRING

Add another input field? Yes

Field name: created_at
Field type: TIMESTAMP

Add another input field? No

=== Step 2: Output Fields ===
Define the output fields and their transformations.

Output field name: email_domain
Is this a passthrough field? No
DSL expression: split(email, '@')[1]

Add another output field? Yes

Output field name: email
Is this a passthrough field? Yes

Add another output field? No

=== Step 3: Filter Condition (Optional) ===
Add a filter condition? No

=== Step 4: Transform Mode ===
Auto-detected mode: one_to_one
Use auto-detected mode? Yes

=== Step 5: Output Format ===
Select output format: yaml

Output file path: transform_extract_domain.yaml

=== Generating Transform Script ===

Transform Mode: one_to_one

Generated Code:
function transform(record) {
    return {
        email: record.email,
        email_domain: split(record.email, '@')[1]
    };
}

YAML written to: transform_extract_domain.yaml
```

---

## Output Formats

### Screen
Prints preview to console with mode and helpers.

### File
Writes wrapped IIFE to `.js` file:
```javascript
(function() {
    function transform(record) {
        return { /* ... */ };
    };
})();
```

### YAML
Generates a `transform` step YAML:
```yaml
- transform:
    from: source_dataset
    to: target_dataset
    script: |
      function transform(record) {
        return {
          email: record.email,
          email_domain: split(record.email, '@')[1]
        };
      }
```

---

## Architectural Notes

### Wizard is a standalone CLI, decoupled from the main binary

The wizard binary has **zero Go-level dependencies on the rest of the codebase**:

```
$ grep -rn "wizard\." --include="*.go" cmd internal pkg | wc -l
0
```

The integration contract is **YAML pipeline files**, not Go types. Flow:

```
User prompts → WizardState (in-memory) → generator.Generate() → pipeline.yaml → mass-migrator (separate process)
```

This means `cmd/wizard/main.go` can be removed, replaced, or rewritten in another
language without touching anything in `internal/` or `cmd/mass-migrator/`. The
trade-off is no compile-time guarantee that wizard output is valid for the
current mass-migrator binary — validation happens when the YAML is parsed at
pipeline start.

### Three `FieldInfo` types coexist by design

The codebase has **three distinct `FieldInfo` struct types** in three packages.
They are not interchangeable:

| Package | Path | Fields | Purpose |
|---|---|---|---|
| `main` (wizard) | `cmd/wizard/main.go:19` | `Name, Type` | Wizard input-field prompt state |
| `generator` | `internal/generator/generator.go:47` | `Name, Type` | Generator input contract |
| `config` | `internal/config/registry.go:13` | `Name, Help, Group, Type, Default, MapstructureTag` | CLI flag metadata registry |

The wizard's and generator's `FieldInfo` are field-by-field identical but live
in different packages on purpose: the wizard owns the user-facing prompt state;
the generator owns the code-generation input contract. Either could grow fields
the other does not need.

The config registry's `FieldInfo` is a completely different concept (CLI flag
metadata) and shares only the name.

**Naming-collision detection**: the `2026-06-01` graphify run surfaced this as
"1,038 weakly-connected nodes including FieldInfo, TransformField, WizardState"
because the AST extractor cannot tell that three same-named types are
intentionally separate. This document is the authoritative answer to that
graph signal.

**Future cleanup option** (not currently planned): unify wizard's and
generator's `FieldInfo` by having wizard import `internal/generator.FieldInfo`.
This would eliminate the duplication but breaks the "wizard is fully
decoupled" property — a deliberate trade-off the team has chosen against.

---

## Related Components

- **`internal/dsl/`** - DSL parser and AST (ParseString, Node, HasArrayReturn)
- **`internal/transform/engine.go`** - Transform execution runtime (goja, helpers)
- **`internal/generator/generator.go`** - Code generator the wizard drives (`generator.FieldInfo`, `generator.Options`)
- **`internal/config/registry.go`** - Unrelated config-flag registry that also has a `FieldInfo` type (see Architectural Notes)
- **`docs/transform-helpers-reference.md`** - 148 available transform helper functions
- **`cmd/gen-script/main.go`** - Alternative: generate script from YAML template

---

## See Also

- [Transform Helpers Reference](../transform-helpers-reference.md) - All 148 available functions
- [Pipeline DX Design](../plans/2026-04-30-pipeline-dx-design.md) - Templates and linting
