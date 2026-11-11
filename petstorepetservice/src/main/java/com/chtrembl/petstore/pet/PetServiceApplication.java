package com.chtrembl.petstore.pet;

import com.chtrembl.petstore.pet.model.ContainerEnvironment;
import com.chtrembl.petstore.pet.model.DataPreload;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.ExitCodeGenerator;
import com.microsoft.applicationinsights.attach.ApplicationInsights;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class PetServiceApplication implements CommandLineRunner {

	@Bean
	public ContainerEnvironment containerEnvvironment() {
		return new ContainerEnvironment();
	}

	@Bean
	public DataPreload dataPreload() {
		return new DataPreload();
	}

	@Override
	public void run(String... arg0) throws Exception {
		if (arg0.length > 0 && arg0[0].equals("exitcode")) {
			throw new ExitException();
		}
	}

	public static void main(String[] args) throws Exception {
        attachApplicationInsights();   // Module 5: agent first, before Spring starts
        new SpringApplication(PetServiceApplication.class).run(args);
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

	class ExitException extends RuntimeException implements ExitCodeGenerator {
		private static final long serialVersionUID = 1L;

		@Override
		public int getExitCode() {
			return 10;
		}

	}
}
