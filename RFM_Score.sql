-- Xác định đơn hàng hợp lệ

-- total amount including shipping fee
WITH order_total AS (
    SELECT
        o.customer_id,
        o.order_id,
        SUM(oi.quantity * oi.unit_price) 
            + COALESCE(o.shipping_fee, 0) AS order_total
    FROM orders o
    JOIN order_items oi 
        ON o.order_id = oi.order_id
    GROUP BY 
        o.order_id, 
        o.customer_id, 
        o.shipping_fee
),
paid_total AS (
    SELECT
        p.order_id,
        SUM(p.paid_amount) AS paid_total
    FROM payments p
    WHERE p.payment_status = 'paid'
    GROUP BY p.order_id
),
validated AS (
    SELECT
        ot.customer_id,
        ot.order_total,
        ot.order_id
    FROM order_total ot
    JOIN paid_total pt 
        ON ot.order_id = pt.order_id
    WHERE ABS(ot.order_total - pt.paid_total) = 0
),
last_order AS(
    SELECT
        v.customer_id,
        MAX(o.order_date) AS last_order_date
    FROM validated v
    JOIN orders o ON o.order_id = v.order_id
    GROUP BY v.customer_id
),
-- Xác định ngày đặt hàng gần nhất của từng khách hàng
recency AS(
    SELECT
        lo.customer_id,
        timestampdiff(day, lo.last_order_date,
            (SELECT MAX(order_date) FROM orders)) AS recency
    FROM last_order lo
),
-- Tính số ngày kể từ lần mua gần nhất đến ngày đặt hàng lớn nhất trong dataset (recency)
calculate AS(
    SELECT
        v.customer_id,
        SUM(v.order_total) AS monetary,
        COUNT(DISTINCT v.order_id) AS frequency
    FROM validated v
    GROUP BY v.customer_id
),
-- Tính tổng chi tiêu (monetary) và tổng đơn đặt hàng (frequency) của từng khách hàng
pct_ranking AS(
    SELECT
        c.customer_id,
        r.recency,
        c.frequency,
        c.monetary,

        percent_rank() over(ORDER BY r.recency DESC) AS pct_recency,
        percent_rank() over(ORDER BY c.frequency ASC) AS pct_frequency,
        percent_rank() over(ORDER BY c.monetary ASC) AS pct_monetary

    FROM calculate c
    JOIN recency r ON c.customer_id = r.customer_id
),
-- Xếp hạng tương đối 3 chỉ số RFM của từng khách hàng
scoring AS(
    SELECT
        pr.*,

        CASE
            WHEN pct_recency <= 0.2 THEN 1
            WHEN pct_recency <= 0.4 THEN 2
            WHEN pct_recency <= 0.6 THEN 3
            WHEN pct_recency <= 0.8 THEN 4
            ELSE 5
        END AS r_score,

        CASE
            WHEN pct_frequency <= 0.2 THEN 1
            WHEN pct_frequency <= 0.4 THEN 2
            WHEN pct_frequency <= 0.6 THEN 3
            WHEN pct_frequency <= 0.8 THEN 4
            ELSE 5
        END AS f_score,

        CASE
            WHEN pct_monetary <= 0.2 THEN 1
            WHEN pct_monetary <= 0.4 THEN 2
            WHEN pct_monetary <= 0.6 THEN 3
            WHEN pct_monetary <= 0.8 THEN 4
            ELSE 5
        END AS m_score

    FROM pct_ranking pr
),
-- Quy đổi thứ hạng tương đối của từng chỉ số thành điểm từ 1 đến 5
segment AS(
    SELECT
        s.*,

        SUM(s.frequency) OVER() AS all_order,
        -- Tính tổng số đơn hàng của dataset

        SUM(s.monetary) OVER() AS all_revenue,
        -- Tính tổng doanh thu của dataset

        COUNT(s.customer_id) OVER() AS all_customer,
        -- Đếm tổng số lượng khách hàng

        CASE
            WHEN r_score = 5 AND f_score = 5 AND m_score = 5 THEN 'Champion'
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'VIP'
            WHEN f_score >= 4 AND m_score >= 4 THEN 'Loyal'
            WHEN m_score >= 4 THEN 'Big Spender'
            WHEN r_score >= 3 AND f_score >= 3 THEN 'Potential Loyalist'
            WHEN r_score >= 4 AND f_score <= 2 THEN 'New Customer'
            WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
            WHEN r_score <= 2 AND f_score <= 2 THEN 'Lost'
            ELSE 'General'
        END AS RFM_segment

    FROM scoring s
),
-- Dựa vào 3 chỉ số R, F, M đã tính bên trên, đánh giá phân khúc cho từng khách hàng
all_segment AS(
    SELECT 'Champion' AS RFM_segment UNION ALL
    SELECT 'VIP' UNION ALL
    SELECT 'Loyal' UNION ALL
    SELECT 'Big Spender' UNION ALL
    SELECT 'Potential Loyalist' UNION ALL
    SELECT 'New Customer' UNION ALL
    SELECT 'At Risk' UNION ALL
    SELECT 'Lost' UNION ALL
    SELECT 'General'
    -- Tạo danh sách đầy đủ các phân khúc RFM để đảm bảo mọi nhóm đều xuất hiện trong kết quả
)

SELECT
    als.RFM_segment,
    COUNT(DISTINCT s.customer_id) AS total_customer,
    -- Tổng số khách hàng của từng phân khúc
    SUM(s.frequency) AS total_order,
    -- Tổng số đơn hàng của từng phân khúc
    SUM(s.monetary) AS total_revenue,
    -- Tổng doanh thu của từng phân khúc
    (COUNT(DISTINCT s.customer_id) * 1.0 / max(s.all_customer)) * 100 AS pct_customer,
    -- Tỉ lệ khách hàng của phân khúc
    (SUM(s.frequency) * 1.0 / max(s.all_order)) * 100 AS pct_orders,
    -- Tỉ lệ đơn hàng của phân khúc
    (SUM(s.monetary) * 1.0 / max(s.all_revenue)) * 100 AS pct_revenue
    -- Tỉ lệ doanh thu của phân khúc
FROM all_segment als
LEFT JOIN segment s
    ON s.RFM_segment = als.RFM_segment
GROUP BY als.RFM_segment
ORDER BY FIELD(
    als.RFM_segment,
    'Champion',
    'VIP',
    'Loyal',
    'Big Spender',
    'Potential Loyalist',
    'New Customer',
    'At Risk',
    'Lost',
    'General'
)



