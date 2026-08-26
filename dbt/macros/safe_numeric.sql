{% macro safe_numeric(column) %}
    case
        when {{ column }} ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
        then ({{ column }})::numeric
    end
{% endmacro %}
