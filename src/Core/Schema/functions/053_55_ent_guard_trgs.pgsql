-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: triggers using ent_guard (053_54) and pay_no_truncate (035_24)
CREATE OR REPLACE TRIGGER ent_entitlements_guard BEFORE UPDATE OR DELETE ON ent_entitlements FOR EACH ROW EXECUTE FUNCTION ent_guard();
CREATE OR REPLACE TRIGGER ent_activations_guard  BEFORE UPDATE OR DELETE ON ent_activations  FOR EACH ROW EXECUTE FUNCTION ent_guard();
CREATE OR REPLACE TRIGGER ent_billing_runs_guard BEFORE UPDATE OR DELETE ON ent_billing_runs FOR EACH ROW EXECUTE FUNCTION ent_guard();
CREATE OR REPLACE TRIGGER ent_entitlements_no_truncate BEFORE TRUNCATE ON ent_entitlements FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER ent_activations_no_truncate  BEFORE TRUNCATE ON ent_activations  FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
CREATE OR REPLACE TRIGGER ent_billing_runs_no_truncate BEFORE TRUNCATE ON ent_billing_runs FOR EACH STATEMENT EXECUTE FUNCTION pay_no_truncate();
