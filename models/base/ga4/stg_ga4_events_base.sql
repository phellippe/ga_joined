
{{config(materialized = 'table')}}
--BigQuery does not cache wildcard queries that scan across sharded tables which means it's best to materialize the raw event data as a partitioned table so that future queries benefit from caching
with source as (
    select 
        parse_date('%Y%m%d',event_date) as event_date_dt,
        event_timestamp,
        event_name,
        event_params,
        event_previous_timestamp,
        event_value_in_usd,
        event_bundle_sequence_id,
        event_server_timestamp_offset,
        user_id,
        user_pseudo_id,
        privacy_info,
        user_properties,
        user_first_touch_timestamp,
        user_ltv,
        device,
        geo,
        app_info,
        traffic_source,
        stream_id,
        platform,
        ecommerce,
        items
        from {{ ref('stg_ga4_events_union') }}
),
renamed as (
    select 
        event_date_dt,
        event_timestamp,
        lower(replace(trim(event_name), " ", "_")) as event_name, -- Clean up all event names to be snake cased
        event_params,
        event_previous_timestamp,
        event_value_in_usd,
        event_bundle_sequence_id,
        event_server_timestamp_offset,
        user_id,
        user_pseudo_id,
        privacy_info.analytics_storage as privacy_info_analytics_storage,
        privacy_info.ads_storage as privacy_info_ads_storage,
        privacy_info.uses_transient_token as privacy_info_uses_transient_token,
        user_properties,
        user_first_touch_timestamp,
        user_ltv.revenue as user_ltv_revenue,
        user_ltv.currency as user_ltv_currency,
        device.category as device_category,
        device.mobile_brand_name as device_mobile_brand_name,
        device.mobile_model_name as device_mobile_model_name,
        device.mobile_marketing_name as device_mobile_marketing_name,
        device.mobile_os_hardware_model as device_mobile_os_hardware_model,
        device.operating_system as device_operating_system,
        device.operating_system_version as device_operating_system_version,
        device.vendor_id as device_vendor_id,
        device.advertising_id as device_advertising_id,
        device.language as device_language,
        device.is_limited_ad_tracking as device_is_limited_ad_tracking,
        device.time_zone_offset_seconds as device_time_zone_offset_seconds,
        device.browser as device_browser,
        device.browser_version as device_browser_version,
        device.web_info.browser as device_web_info_browser,
        device.web_info.browser_version as device_web_info_browser_version,
        device.web_info.hostname as device_web_info_hostname,
        geo.continent as geo_continent,
        geo.country as geo_country,
        geo.region as geo_region,
        geo.city as geo_city,
        geo.sub_continent as geo_sub_continent,
        geo.metro as geo_metro,
        app_info.id as app_info_id,
        app_info.version as app_info_version,
        app_info.install_store as app_info_install_store,
        app_info.firebase_app_id as app_info_firebase_app_id,
        app_info.install_source as app_info_install_source,
        traffic_source.name as traffic_source_name,
        traffic_source.medium as traffic_source_medium,
        traffic_source.source as traffic_source_source,
        stream_id,
        platform,
        ecommerce,
        items,
        (select value.int_value from unnest(event_params) where key = 'ga_session_id') as ga_session_id,
        (select value.string_value from unnest(event_params) where key = 'page_location') as page_location,
        (select value.int_value from unnest(event_params) where key = 'ga_session_number') as ga_session_number,
        (case when (SELECT value.string_value FROM unnest(event_params) where key = "session_engaged") = "1" then 1 end) as session_engaged,
        (select value.int_value from unnest(event_params) where key = 'engagement_time_msec') as engagement_time_msec,
        (select value.string_value from unnest(event_params) where key = 'page_title') as page_title,
        (select value.string_value from unnest(event_params) where key = 'page_referrer') as page_referrer,
        (select value.string_value from unnest(event_params) where key = 'source') as source,
        (select value.string_value from unnest(event_params) where key = 'medium') as medium,
        (select value.string_value from unnest(event_params) where key = 'campaign') as campaign,
        (select value.string_value from unnest(event_params) where key = 'content') as content,
        (select value.string_value from unnest(event_params) where key = 'term') as term,
        CASE 
            WHEN event_name = 'page_view' THEN 1
            ELSE 0
        END AS is_page_view,
        CASE 
            WHEN event_name = 'purchase' THEN 1
            ELSE 0
        END AS is_purchase,
        case 
            when event_name = 'affiliate_link_click' then 1
            else 0
        end as is_affiliate_link_click,
        case 
            when event_name = 'click_top_10' then 1
            else 0
        end as is_affiliate_top10_click
    from source
), 
calculation as (
        select 
                *,
                to_base64(md5(concat(stream_id, user_pseudo_id, cast(ga_session_id as string)))) as session_key
        from renamed
),
data as (
     select 
        distinct 
        ga_session_id
        ,event_timestamp
        ,user_pseudo_id
        ,geo_country
        ,event_date_dt as date
        , trim(lower(regexp_replace(replace(replace(replace(page_location, 'www.', ''), 'http://', ''), 'https://', ''), r'\#.*$', '')), '/') as landing_page
        ,countif(is_affiliate_link_click = 1) as affiliate_clicks_conversion
        ,countif(is_affiliate_top10_click = 1) as affiliate_top10_clicks_conversion
        ,max(case when page_location like '/complaint-received%' and traffic_source_medium = 'organic' then 1 else 0 end) complaint_received_conversion
        ,count(distinct session_key) as sessions
        ,countif(is_page_view = 1) as pageviews
    from calculation
    group by 1,2,3,4,5,6
 )
select
date,
date_trunc(date, month) month_date,
landing_page,
geo_country as country,
sum(sessions) sessions,
sum(pageviews) pageviews,
count(case when affiliate_clicks_conversion = 1 then user_pseudo_id end) affiliate_click_conversions,
count(case when affiliate_top10_clicks_conversion = 1 then user_pseudo_id end) affiliate_top10_click_conversions,
count(case when complaint_received_conversion = 1 then user_pseudo_id end) complaint_received_conversions,
count(case when affiliate_clicks_conversion = 1 then user_pseudo_id end) + count(case when affiliate_top10_clicks_conversion = 1 then user_pseudo_id end) + count(case when complaint_received_conversion = 1 then user_pseudo_id end) as conversions
from data
group by date, landing_page, country