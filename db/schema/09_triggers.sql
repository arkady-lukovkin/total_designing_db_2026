-- Объявления триггеров после таблиц и всех триггерных функций.
BEGIN;
SET LOCAL search_path = lukovkin_food, pg_catalog;

CREATE TRIGGER position_restaurant
BEFORE INSERT OR UPDATE ON order_structure
FOR EACH ROW
EXECUTE FUNCTION check_position_restaurant();

CREATE TRIGGER product_restaurant_change
BEFORE UPDATE OF restaurant_id ON product
FOR EACH ROW
WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION guard_restaurant_change();

CREATE TRIGGER order_restaurant_change
BEFORE UPDATE OF restaurant_id ON "order"
FOR EACH ROW
WHEN (OLD.restaurant_id IS DISTINCT FROM NEW.restaurant_id)
EXECUTE FUNCTION guard_restaurant_change();

CREATE CONSTRAINT TRIGGER complete_order
AFTER INSERT OR UPDATE ON "order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION order_integrity();

CREATE CONSTRAINT TRIGGER complete_positions
AFTER INSERT OR UPDATE OR DELETE ON order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION order_integrity();

CREATE CONSTRAINT TRIGGER complete_payments
AFTER INSERT OR UPDATE OR DELETE ON payment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION order_integrity();

CREATE TRIGGER payment_insert_status
AFTER INSERT ON payment
REFERENCING NEW TABLE AS new_payments
FOR EACH STATEMENT
EXECUTE FUNCTION sync_payment_status();

CREATE TRIGGER positions_truncate_integrity
AFTER TRUNCATE ON order_structure
FOR EACH STATEMENT
EXECUTE FUNCTION guard_order_truncate();

CREATE TRIGGER payments_truncate_integrity
AFTER TRUNCATE ON payment
FOR EACH STATEMENT
EXECUTE FUNCTION guard_order_truncate();

CREATE TRIGGER payment_update_status
AFTER UPDATE ON payment
REFERENCING OLD TABLE AS old_payments NEW TABLE AS new_payments
FOR EACH STATEMENT
EXECUTE FUNCTION sync_payment_status();

CREATE TRIGGER payment_delete_status
AFTER DELETE ON payment
REFERENCING OLD TABLE AS old_payments
FOR EACH STATEMENT
EXECUTE FUNCTION sync_payment_status();

CREATE TRIGGER review_rating_change
AFTER INSERT OR UPDATE OR DELETE ON review
FOR EACH ROW
EXECUTE FUNCTION rating_change();

CREATE CONSTRAINT TRIGGER product_rating_insert_integrity
AFTER INSERT ON product
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_rating_integrity();

CREATE CONSTRAINT TRIGGER product_rating_update_integrity
AFTER UPDATE ON product
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
WHEN (OLD.rating IS DISTINCT FROM NEW.rating)
EXECUTE FUNCTION check_rating_integrity();

CREATE CONSTRAINT TRIGGER restaurant_rating_integrity
AFTER INSERT OR UPDATE ON restaurant
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_rating_integrity();

CREATE CONSTRAINT TRIGGER review_rating_integrity
AFTER INSERT OR UPDATE OR DELETE ON review
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_rating_integrity();

CREATE TRIGGER review_clear_ratings
BEFORE TRUNCATE ON review
FOR EACH STATEMENT
EXECUTE FUNCTION clear_ratings();

COMMIT;
