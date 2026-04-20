package io.apicurio.testing.converter;

import io.apicurio.registry.serde.avro.AvroKafkaDeserializer;
import io.apicurio.registry.serde.avro.AvroKafkaSerializer;
import io.apicurio.registry.serde.avro.AvroSerdeConfig;
import io.apicurio.registry.serde.avro.DefaultAvroDatumProvider;
import io.apicurio.registry.serde.config.SerdeConfig;
import io.apicurio.registry.utils.converter.AvroConverter;
import io.apicurio.registry.utils.converter.ExtJsonConverter;
import io.apicurio.registry.utils.converter.SerdeBasedConverter;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaAndValue;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;

import java.util.HashMap;
import java.util.Map;

/**
 * Standalone test application for Apicurio Registry Kafka Connect converters.
 *
 * Tests:
 * 1. AvroConverter - serialization/deserialization roundtrip
 * 2. ExtJsonConverter - serialization/deserialization roundtrip
 * 3. SerdeBasedConverter - manual serde configuration
 * 4. Schema registration verification
 */
public class ConverterTestApp {

    private static final String DEFAULT_REGISTRY_URL = "http://localhost:8080/apis/registry/v3";

    private static int testsPassed = 0;
    private static int testsFailed = 0;

    public static void main(String[] args) {
        String registryUrl = System.getenv().getOrDefault("REGISTRY_URL", DEFAULT_REGISTRY_URL);

        System.out.println("=========================================");
        System.out.println("  Kafka Connect Converter Test");
        System.out.println("=========================================");
        System.out.println("Registry URL: " + registryUrl);
        System.out.println("=========================================");
        System.out.println();

        // Run all tests
        testAvroConverterSimpleStruct(registryUrl);
        testAvroConverterWithDefaults(registryUrl);
        testExtJsonConverterSimpleStruct(registryUrl);
        testSerdeBasedConverter(registryUrl);
        testAvroConverterNullHandling(registryUrl);

        // Summary
        System.out.println();
        System.out.println("=========================================");
        System.out.println("  TEST RESULTS");
        System.out.println("=========================================");
        System.out.println("  Passed: " + testsPassed);
        System.out.println("  Failed: " + testsFailed);
        System.out.println("  Total:  " + (testsPassed + testsFailed));
        System.out.println("=========================================");

        if (testsFailed > 0) {
            System.out.println("OVERALL: FAILED");
            System.exit(1);
        } else {
            System.out.println("OVERALL: PASSED");
        }
    }

    /**
     * Test 1: AvroConverter with a simple struct (string field)
     */
    private static void testAvroConverterSimpleStruct(String registryUrl) {
        String testName = "AvroConverter - Simple Struct";
        System.out.println("--- Test: " + testName + " ---");

        try (AvroConverter converter = new AvroConverter()) {
            Map<String, Object> config = new HashMap<>();
            config.put(SerdeConfig.REGISTRY_URL, registryUrl);
            config.put(SerdeConfig.AUTO_REGISTER_ARTIFACT, "true");
            converter.configure(config, false);

            // Create a simple struct schema
            Schema schema = SchemaBuilder.struct()
                    .field("name", Schema.STRING_SCHEMA)
                    .field("value", Schema.STRING_SCHEMA)
                    .build();

            Struct original = new Struct(schema);
            original.put("name", "test-key");
            original.put("value", "test-value");

            String topic = "converter_test_avro_simple";

            // Serialize (fromConnectData)
            byte[] serialized = converter.fromConnectData(topic, schema, original);
            assertNotNull(serialized, "Serialized bytes should not be null");
            assertTrue(serialized.length > 0, "Serialized bytes should not be empty");

            // Deserialize (toConnectData)
            SchemaAndValue result = converter.toConnectData(topic, serialized);
            assertNotNull(result, "Deserialized result should not be null");
            assertNotNull(result.value(), "Deserialized value should not be null");

            Struct deserialized = (Struct) result.value();
            assertEquals("test-key", deserialized.get("name").toString(), "Name field");
            assertEquals("test-value", deserialized.get("value").toString(), "Value field");

            pass(testName);
        } catch (Exception e) {
            fail(testName, e);
        }
    }

    /**
     * Test 2: AvroConverter with default values and optional fields
     */
    private static void testAvroConverterWithDefaults(String registryUrl) {
        String testName = "AvroConverter - Defaults and Optional Fields";
        System.out.println("--- Test: " + testName + " ---");

        try (AvroConverter converter = new AvroConverter()) {
            Map<String, Object> config = new HashMap<>();
            config.put(SerdeConfig.REGISTRY_URL, registryUrl);
            config.put(SerdeConfig.AUTO_REGISTER_ARTIFACT, "true");
            converter.configure(config, false);

            Schema schema = SchemaBuilder.struct()
                    .field("id", Schema.INT32_SCHEMA)
                    .field("description", SchemaBuilder.string().optional().defaultValue("no description").build())
                    .build();

            Struct original = new Struct(schema);
            original.put("id", 42);
            original.put("description", "test description");

            String topic = "converter_test_avro_defaults";

            byte[] serialized = converter.fromConnectData(topic, schema, original);
            SchemaAndValue result = converter.toConnectData(topic, serialized);

            Struct deserialized = (Struct) result.value();
            assertEquals(42, (int) deserialized.getInt32("id"), "ID field");
            assertEquals("test description", deserialized.get("description").toString(), "Description field");

            pass(testName);
        } catch (Exception e) {
            fail(testName, e);
        }
    }

    /**
     * Test 3: ExtJsonConverter with a simple struct
     */
    private static void testExtJsonConverterSimpleStruct(String registryUrl) {
        String testName = "ExtJsonConverter - Simple Struct";
        System.out.println("--- Test: " + testName + " ---");

        try (ExtJsonConverter converter = new ExtJsonConverter()) {
            Map<String, Object> config = new HashMap<>();
            config.put(SerdeConfig.REGISTRY_URL, registryUrl);
            config.put(SerdeConfig.AUTO_REGISTER_ARTIFACT, "true");
            converter.configure(config, false);

            Schema schema = SchemaBuilder.struct()
                    .field("message", Schema.STRING_SCHEMA)
                    .build();

            Struct original = new Struct(schema);
            original.put("message", "hello from ExtJson converter");

            String topic = "converter_test_extjson";

            byte[] serialized = converter.fromConnectData(topic, schema, original);
            assertNotNull(serialized, "Serialized bytes should not be null");

            SchemaAndValue result = converter.toConnectData(topic, serialized);
            assertNotNull(result, "Deserialized result should not be null");

            Struct deserialized = (Struct) result.value();
            assertEquals("hello from ExtJson converter", deserialized.get("message").toString(), "Message field");

            pass(testName);
        } catch (Exception e) {
            fail(testName, e);
        }
    }

    /**
     * Test 4: SerdeBasedConverter with explicit serializer/deserializer
     */
    private static void testSerdeBasedConverter(String registryUrl) {
        String testName = "SerdeBasedConverter - Explicit SerDe Config";
        System.out.println("--- Test: " + testName + " ---");

        try (SerdeBasedConverter converter = new SerdeBasedConverter()) {
            Map<String, Object> config = new HashMap<>();
            config.put(SerdeConfig.REGISTRY_URL, registryUrl);
            config.put(SerdeConfig.AUTO_REGISTER_ARTIFACT, "true");
            config.put(SerdeBasedConverter.REGISTRY_CONVERTER_SERIALIZER_PARAM,
                    AvroKafkaSerializer.class.getName());
            config.put(SerdeBasedConverter.REGISTRY_CONVERTER_DESERIALIZER_PARAM,
                    AvroKafkaDeserializer.class.getName());
            config.put(AvroSerdeConfig.AVRO_DATUM_PROVIDER, DefaultAvroDatumProvider.class.getName());
            converter.configure(config, false);

            Schema schema = SchemaBuilder.struct()
                    .field("key", Schema.STRING_SCHEMA)
                    .field("count", Schema.INT32_SCHEMA)
                    .build();

            Struct original = new Struct(schema);
            original.put("key", "serde-test");
            original.put("count", 99);

            String topic = "converter_test_serde_based";

            byte[] serialized = converter.fromConnectData(topic, schema, original);
            assertNotNull(serialized, "Serialized bytes should not be null");

            SchemaAndValue result = converter.toConnectData(topic, serialized);
            assertNotNull(result, "Deserialized result should not be null");

            pass(testName);
        } catch (Exception e) {
            fail(testName, e);
        }
    }

    /**
     * Test 5: AvroConverter null payload handling
     */
    private static void testAvroConverterNullHandling(String registryUrl) {
        String testName = "AvroConverter - Null Payload";
        System.out.println("--- Test: " + testName + " ---");

        try (AvroConverter converter = new AvroConverter()) {
            Map<String, Object> config = new HashMap<>();
            config.put(SerdeConfig.REGISTRY_URL, registryUrl);
            converter.configure(config, false);

            SchemaAndValue result = converter.toConnectData("test-null-topic", null);
            assertNotNull(result, "Result should not be null for null input");

            pass(testName);
        } catch (Exception e) {
            fail(testName, e);
        }
    }

    // --- Assertion helpers ---

    private static void assertNotNull(Object value, String message) {
        if (value == null) {
            throw new AssertionError("Assertion failed: " + message + " (expected non-null, got null)");
        }
    }

    private static void assertTrue(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError("Assertion failed: " + message);
        }
    }

    private static void assertEquals(Object expected, Object actual, String fieldName) {
        if (!expected.equals(actual)) {
            throw new AssertionError("Assertion failed for " + fieldName +
                    ": expected '" + expected + "', got '" + actual + "'");
        }
    }

    private static void pass(String testName) {
        testsPassed++;
        System.out.println("  PASSED: " + testName);
        System.out.println();
    }

    private static void fail(String testName, Exception e) {
        testsFailed++;
        System.out.println("  FAILED: " + testName);
        System.out.println("  Error: " + e.getMessage());
        e.printStackTrace(System.out);
        System.out.println();
    }
}
