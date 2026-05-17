WITH order_total AS (
    SELECT
        o.customer_id,
        o.order_id,
        SUM(oi.quantity * oi.unit_price) + COALESCE(o.shipping_fee, 0) AS order_total
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
    WHERE ABS(ot.order_total - pt.paid_total) <= 0.01
),
order_month AS(
    SELECT DISTINCT
        o.customer_id,
        CAST(DATE_FORMAT(o.order_date, '%Y-%m-01') AS DATE) AS order_month
        -- Quy order_date về ngày đầu tháng để đưa level của dữ liệu từ day về month
        -- CAST giúp chuẩn hóa kết quả về kiểu DATE
    FROM validated v
    JOIN orders o
        ON v.order_id = o.order_id
),
-- Mỗi khách chỉ giữ 1 dòng cho mỗi tháng có đơn hợp lệ bằng DISTINCT

first_purchase AS(
    SELECT
        om.customer_id,
        MIN(om.order_month) AS cohort_month
    FROM order_month om
    GROUP BY om.customer_id
),
-- Xác định tháng mua hàng đầu tiên của từng khách để gán cohort_month
cohort_activity AS(
    SELECT
        om.customer_id,
        fp.cohort_month,
        om.order_month
    FROM order_month om
    JOIN first_purchase fp
        ON om.customer_id = fp.customer_id
),
-- Gán cohort_month của từng khách với tất cả các tháng mà khách đó còn phát sinh mua hàng

active_customers AS(
    SELECT
        cohort_month,
        order_month,
        COUNT(DISTINCT customer_id) AS active_customers
    FROM cohort_activity
    GROUP BY cohort_month, order_month
),
-- Đếm số khách hàng hoạt động ở từng tháng của mỗi cohort
cohort_size AS(
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS cohort_size
    FROM first_purchase
    GROUP BY cohort_month
)
-- Đếm tổng số khách ban đầu trong mỗi cohort để làm mẫu số cho retention rate

SELECT
    ac.cohort_month,
    TIMESTAMPDIFF(
        MONTH,
        ac.cohort_month,
        ac.order_month
    ) AS month_number,
    -- Tính số tháng chênh lệch giữa cohort_month và order_month
    -- Ví dụ:
    -- cohort_month = 2024-01-01, order_month = 2024-01-01 → month_number = 0
    -- cohort_month = 2024-01-01, order_month = 2024-02-01 → month_number = 1
    ac.active_customers,
    (ac.active_customers * 100.0 / cs.cohort_size) AS retention_rate
    -- Tính tỷ lệ khách còn active trên tổng số khách ban đầu của cohort
FROM active_customers ac
JOIN cohort_size cs
    ON ac.cohort_month = cs.cohort_month
ORDER BY
    ac.cohort_month, month_number
-- Sắp xếp kết quả theo từng cohort và theo thứ tự tháng để vẽ retention chart