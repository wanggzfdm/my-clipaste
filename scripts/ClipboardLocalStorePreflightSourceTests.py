from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
FACTORY = ROOT / "clipaste/Managers/ClipboardModelContainerFactory.swift"
MODEL = ROOT / "clipaste/Models/ClipboardGroupModel.swift"


class ClipboardLocalStorePreflightSourceTests(unittest.TestCase):
    def test_repair_is_local_and_checks_table_and_column(self):
        source = FACTORY.read_text()
        self.assertIn('appendingPathComponent("clipboard-local.store"', source)
        self.assertIn("repairNullDeletedByDevice(in: localStoreURL)", source)
        self.assertIn("ZCLIPBOARDGROUPMODEL", source)
        self.assertIn("ZDELETEDBYDEVICE", source)
        self.assertIn("WHERE ZDELETEDBYDEVICE IS NULL", source)
        self.assertIn("fileExists(atPath: storeURL.path)", source)
        self.assertNotIn("clipboard-cloud.store", source)

    def test_model_field_remains_nonoptional(self):
        source = MODEL.read_text()
        self.assertIn('var deletedByDevice: String = ""', source)
        self.assertNotIn("var deletedByDevice: String?", source)


if __name__ == "__main__":
    unittest.main()
