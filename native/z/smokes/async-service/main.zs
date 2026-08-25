import {
  BridgeResponse,
} from "../../framework/bridge.zs";
import {
  AsyncServices,
  createAsyncServices,
} from "../../framework/async-services.zs";
import { AsyncService } from "../../framework/async-service-contract.zs";
import { Service } from "../../framework/services.zs";
import {
  routeMessageWithServicesAsync,
} from "../../framework/async-bridge.zs";
import {
  ServiceInvocation,
  ServiceOutcome,
} from "../../framework/service-contract.zs";
import { scheduler } from "std/async";
import console from "std/console";

readonly class SearchService implements AsyncService {
  readonly prefix: String;

  async function invoke(
    in invocation: ServiceInvocation
  ): ServiceOutcome {
    await scheduler.yield();
    if (this.prefix != "search") {
      return ServiceOutcome.failure("INVALID_SERVICE");
    }
    if (invocation.method != "find") {
      return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
    return ServiceOutcome.success(copy invocation.arguments);
  }
}

readonly class HealthService implements Service {
  function invoke(in invocation: ServiceInvocation): ServiceOutcome {
    if (invocation.method != "status") {
      return ServiceOutcome.failure("UNKNOWN_METHOD");
    }
    return ServiceOutcome.success("healthy");
  }
}

function validate(in response: Option<BridgeResponse>): i32 {
  return match (response) {
    some(value) => {
      if (value.id != 42) return 1;
      if (!value.ok) return 2;
      if (value.payload != '{"query":"Z"}') return 3;
      select 0;
    }
    none => 4;
  };
}

function validateHealth(in response: Option<BridgeResponse>): i32 {
  return match (response) {
    some(value) => {
      if (value.id != 41) return 1;
      if (!value.ok) return 2;
      if (value.payload != "healthy") return 3;
      select 0;
    }
    none => 4;
  };
}

async function validateRoutes(services: AsyncServices): i32 {
  const healthRequest =
    '{"t":1,"id":41,"m":"health.status","a":{}}';
  const healthResponse = await routeMessageWithServicesAsync(
    copy healthRequest,
    services
  );
  const healthStatus = validateHealth(in healthResponse);
  if (healthStatus != 0) return 10 + healthStatus;

  const request =
    '{"t":1,"id":42,"m":"search.find","a":{"query":"Z"}}';
  const response = await routeMessageWithServicesAsync(
    copy request,
    services
  );
  return validate(in response);
}

async function main(): i32 {
  let builder = createAsyncServices();
  builder.register("health", new HealthService({}));
  builder.registerAsync(
    "search",
    new SearchService({ prefix: "search" })
  );
  const services = builder.freeze();
  const status = await validateRoutes(services);
  if (status != 0) return status;

  console.log(
    "Zapp async service smoke passed: sync + suspended async routes"
  );
  return 0;
}
