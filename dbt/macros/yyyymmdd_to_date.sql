{% macro yyyymmdd_to_date(column) %}
    case
        when {{ column }} ~ '^[0-9]{8}$'
        then to_date({{ column }}, 'YYYYMMDD')
    end
{% endmacro %}
