package com.chtrembl.petstore.product;

import com.microsoft.applicationinsights.attach.ApplicationInsights;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class ProductServiceApplication {

    public static void main(String[] args) {
        attachApplicationInsights();   // Module 5: agent first, before Spring starts
        SpringApplication.run(ProductServiceApplication.class, args);
    }

    // Module 5: same pattern as petstoreapp (runtime attach + on/off switch).
    // Uses System.out (not a logger) so no logging framework starts before the agent is attached.
    private static void attachApplicationInsights() {
        boolean enabled = !"false".equalsIgnoreCase(System.getenv("APPLICATIONINSIGHTS_ENABLED"));
        String connectionString = System.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING");
        if (!enabled || connectionString == null || connectionString.isBlank()) {
            System.out.println("Application Insights not attached (disabled or no connection string)");
            return;
        }
        try {
            ApplicationInsights.attach();
            System.out.println("Application Insights runtime attach requested - confirm with the agent line 'Application Insights Java Agent ... started successfully'");
        } catch (Exception e) {
            System.out.println("Failed to attach Application Insights: " + e.getMessage());
        }
    }
}