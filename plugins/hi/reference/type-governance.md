# Type-information governance (for `/hi:repo-setup`)

Gortex's Python resolver is the native, type-aware `python-types` provider — this
build ships no `lsp-pyright`, so **no** external type checker sits in gortex's
resolution path. What the provider keys off is **type information present in the
source**: annotations + installed stubs. A type checker is only a *governance
mechanism* — it surfaces where that info is thin and pressures you to add it. Any
checker works; the source-side result is what matters.

Two halves, two tools:

- **Resolution** — does each name / member / import resolve to a known type? Only
  a **type checker** (ty / pyright / mypy) measures this.
- **Annotation presence** — do functions carry param/return annotations at all? A
  **linter** (ruff `ANN`) enforces this cheaply on the leaf code a checker won't
  nag about.

Ruff alone can't measure resolution; a checker alone won't push you to annotate
everything. Use both.

## Choosing the checker

- **Already configured** (`[tool.ty]`, `[tool.mypy]`, `[tool.pyright]`) → use it,
  don't impose another.
- **None, on a uv / Astral repo** → **ty** (default): one toolchain with uv + ruff,
  fastest. Caveat: pre-1.0 (v0.0.x) — config keys and rule names still churn, and
  the stub story is thinner than pyright's. Eyes open.
- **Want maturity / best stubs** → **pyright**.
- **Django** → **mypy** + `django-stubs`: it loads the *mypy plugin* that resolves
  manager/queryset return types and dynamic model attributes — which ty and
  pyright cannot. For Django the checker choice materially changes what resolves.

## Config blocks (drop into `pyproject.toml`)

### ty (default) — verified against ty 0.0.57

```toml
[tool.ty.environment]
python-version = "3.13"   # the project's compat floor (requires-python)
python = "./.venv"        # env where deps are installed
root = ["./src"]          # first-party source roots

[tool.ty.src]
include = ["src", "tests"]
exclude = ["**/__pycache__", "build", "dist"]
respect-ignore-files = true

[tool.ty.terminal]
error-on-warning = false  # flip to true once clean, to gate CI

# [tool.ty.rules]  — kebab-case; promote to "error" as you pay gaps down, e.g.
# unresolved-import = "error"
# possibly-unresolved-reference = "warn"
```

Invoke: `uvx ty check` (or `ty check --python .venv`). Rule names and the config
surface are pre-1.0 — re-check `uvx ty check --help` and the docs if a key errors.

### ruff (always-on annotation-presence complement)

```toml
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "ANN"]   # ANN = flake8-annotations
ignore = ["ANN401"]                          # allow explicit Any where deliberate

[tool.ruff.lint.per-file-ignores]
"tests/**" = ["ANN"]   # tests are leaf code — don't force annotations there

[tool.ruff.format]
```

Run: `uvx ruff check` / `uvx ruff format`. (Ruff already removed `ANN101`/`ANN102`
for self/cls — no need to ignore them.)

### pyright (mature fallback)

```toml
[tool.pyright]
pythonVersion = "3.13"
venvPath = "."
venv = ".venv"
include = ["src", "tests"]
exclude = ["**/__pycache__", "**/node_modules", ".venv", "build", "dist"]
useLibraryCodeForTypes = true
typeCheckingMode = "standard"   # ratchet to "strict" once clean

reportMissingImports = "error"
reportMissingModuleSource = "warning"
reportMissingTypeStubs = "warning"
reportAttributeAccessIssue = "error"
reportMissingParameterType = "error"
reportUntypedBaseClass = "error"
reportUntypedNamedTuple = "error"
reportUntypedFunctionDecorator = "warning"
reportUntypedClassDecorator = "warning"
reportUnknownParameterType = "warning"
reportUnknownArgumentType = "warning"
reportUnknownVariableType = "warning"
reportUnknownMemberType = "warning"
reportUnknownLambdaType = "warning"
reportPrivateImportUsage = "warning"
reportWildcardImportFromLibrary = "warning"
reportImplicitOverride = "warning"
```

`reportAny` / `reportExplicitAny` are **basedpyright-only** — standard pyright
prints `Config contains unrecognized setting`. Add them back only if you run
basedpyright.

### mypy (Django)

```toml
[tool.mypy]
python_version = "3.13"
plugins = ["mypy_django_plugin.main"]   # the reason to pick mypy for Django

[tool.django-stubs]
django_settings_module = "myproject.settings"   # set to your settings module
```

## Adoption path

1. Pick the checker; point it at an env with **deps installed** — it can't
   resolve imports it can't see.
2. Install the stubs it flags (`django-stubs`, `djangorestframework-stubs`,
   `celery-types`, `types-requests`, …).
3. Work the missing-annotation / unknown-type diagnostics down — each fix gives
   the native type-aware provider more to resolve against.
4. Ratchet strictness once clean (ty: rules → `error`; pyright: `standard` →
   `strict`).

## Honest limits (true under any checker)

A static checker is not the framework. Even fully clean, plugin-driven and
runtime-registered magic stays partly unresolved — mypy + the `django-stubs`
plugin resolves the most, ty/pyright less. The "often missed" tier still holds:

- signals (`@receiver` / `.connect`), Celery `@shared_task`, admin
  auto-registration, settings string lists (`MIDDLEWARE` / `INSTALLED_APPS`),
  template-name → `.html`, `get_user_model()` / `apps.get_model()`.

**Never act on gortex's "0 usages / dead code" signal for any of those** — it's a
false positive on framework-invoked code regardless of how clean the checker is.
