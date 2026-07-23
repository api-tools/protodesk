export namespace main {

	export class CollectionRequest {
	    workspaceId: string;
	    id: string;
	    collectionId: string;
	    name: string;
	    serverId: string;
	    serverName: string;
	    serverAddress: string;
	    serviceName: string;
	    methodName: string;
	    fullMethod: string;
	    requestJson: string;
	    requestMetadataJson: string;
	    createdAt: string;
	    updatedAt: string;

	    static createFrom(source: any = {}) {
	        return new CollectionRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.workspaceId = source["workspaceId"];
	        this.id = source["id"];
	        this.collectionId = source["collectionId"];
	        this.name = source["name"];
	        this.serverId = source["serverId"];
	        this.serverName = source["serverName"];
	        this.serverAddress = source["serverAddress"];
	        this.serviceName = source["serviceName"];
	        this.methodName = source["methodName"];
	        this.fullMethod = source["fullMethod"];
	        this.requestJson = source["requestJson"];
	        this.requestMetadataJson = source["requestMetadataJson"];
	        this.createdAt = source["createdAt"];
	        this.updatedAt = source["updatedAt"];
	    }
	}
	export class Collection {
	    workspaceId: string;
	    id: string;
	    name: string;
	    description: string;
	    requests: CollectionRequest[];
	    createdAt: string;
	    updatedAt: string;

	    static createFrom(source: any = {}) {
	        return new Collection(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.workspaceId = source["workspaceId"];
	        this.id = source["id"];
	        this.name = source["name"];
	        this.description = source["description"];
	        this.requests = this.convertValues(source["requests"], CollectionRequest);
	        this.createdAt = source["createdAt"];
	        this.updatedAt = source["updatedAt"];
	    }

		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

	export class ConnectRequest {
	    serverAddress: string;
	    tlsEnabled: boolean;
	    reflectionEnabled: boolean;
	    protoFiles: string[];
	    protoFolders: string[];
	    metadata: Record<string, string>;

	    static createFrom(source: any = {}) {
	        return new ConnectRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.serverAddress = source["serverAddress"];
	        this.tlsEnabled = source["tlsEnabled"];
	        this.reflectionEnabled = source["reflectionEnabled"];
	        this.protoFiles = source["protoFiles"];
	        this.protoFolders = source["protoFolders"];
	        this.metadata = source["metadata"];
	    }
	}
	export class GrpcMessageType {
	    fields: GrpcField[];

	    static createFrom(source: any = {}) {
	        return new GrpcMessageType(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.fields = this.convertValues(source["fields"], GrpcField);
	    }

		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class GrpcField {
	    name: string;
	    jsonName: string;
	    type: string;
	    repeated: boolean;
	    map: boolean;
	    messageType?: string;
	    enumValues?: string[];

	    static createFrom(source: any = {}) {
	        return new GrpcField(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.jsonName = source["jsonName"];
	        this.type = source["type"];
	        this.repeated = source["repeated"];
	        this.map = source["map"];
	        this.messageType = source["messageType"];
	        this.enumValues = source["enumValues"];
	    }
	}
	export class GrpcMethod {
	    serviceName: string;
	    methodName: string;
	    fullName: string;
	    requestType: string;
	    responseType: string;
	    clientStreaming: boolean;
	    serverStreaming: boolean;
	    requestFields: GrpcField[];
	    messageTypes?: Record<string, GrpcMessageType>;

	    static createFrom(source: any = {}) {
	        return new GrpcMethod(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.serviceName = source["serviceName"];
	        this.methodName = source["methodName"];
	        this.fullName = source["fullName"];
	        this.requestType = source["requestType"];
	        this.responseType = source["responseType"];
	        this.clientStreaming = source["clientStreaming"];
	        this.serverStreaming = source["serverStreaming"];
	        this.requestFields = this.convertValues(source["requestFields"], GrpcField);
	        this.messageTypes = this.convertValues(source["messageTypes"], GrpcMessageType, true);
	    }

		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class GrpcService {
	    name: string;
	    methods: GrpcMethod[];

	    static createFrom(source: any = {}) {
	        return new GrpcService(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.methods = this.convertValues(source["methods"], GrpcMethod);
	    }

		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class ConnectResponse {
	    state: string;
	    services: GrpcService[];
	    error?: string;
	    reflectionUnavailable?: boolean;
	    descriptorSource?: string;
	    protoSourceError?: string;

	    static createFrom(source: any = {}) {
	        return new ConnectResponse(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.state = source["state"];
	        this.services = this.convertValues(source["services"], GrpcService);
	        this.error = source["error"];
	        this.reflectionUnavailable = source["reflectionUnavailable"];
	        this.descriptorSource = source["descriptorSource"];
	        this.protoSourceError = source["protoSourceError"];
	    }

		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}




	export class HistoryItem {
	    workspaceId: string;
	    id: string;
	    serverId: string;
	    serverName: string;
	    serverAddress: string;
	    serviceName: string;
	    methodName: string;
	    fullMethod: string;
	    requestJson: string;
	    requestMetadataJson: string;
	    responseJson: string;
	    statusCode: string;
	    statusMessage?: string;
	    durationMs: number;
	    error?: string;
	    createdAt: string;

	    static createFrom(source: any = {}) {
	        return new HistoryItem(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.workspaceId = source["workspaceId"];
	        this.id = source["id"];
	        this.serverId = source["serverId"];
	        this.serverName = source["serverName"];
	        this.serverAddress = source["serverAddress"];
	        this.serviceName = source["serviceName"];
	        this.methodName = source["methodName"];
	        this.fullMethod = source["fullMethod"];
	        this.requestJson = source["requestJson"];
	        this.requestMetadataJson = source["requestMetadataJson"];
	        this.responseJson = source["responseJson"];
	        this.statusCode = source["statusCode"];
	        this.statusMessage = source["statusMessage"];
	        this.durationMs = source["durationMs"];
	        this.error = source["error"];
	        this.createdAt = source["createdAt"];
	    }
	}
	export class InvokeRequest {
	    serverAddress: string;
	    fullMethod: string;
	    bodyJson: string;
	    metadata: Record<string, string>;
	    timeoutMs: number;
	    authority?: string;

	    static createFrom(source: any = {}) {
	        return new InvokeRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.serverAddress = source["serverAddress"];
	        this.fullMethod = source["fullMethod"];
	        this.bodyJson = source["bodyJson"];
	        this.metadata = source["metadata"];
	        this.timeoutMs = source["timeoutMs"];
	        this.authority = source["authority"];
	    }
	}
	export class InvokeResponse {
	    ok: boolean;
	    statusCode: string;
	    statusMessage?: string;
	    durationMs: number;
	    bodyJson?: string;
	    responseMetadata?: Record<string, string>;
	    error?: string;

	    static createFrom(source: any = {}) {
	        return new InvokeResponse(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.ok = source["ok"];
	        this.statusCode = source["statusCode"];
	        this.statusMessage = source["statusMessage"];
	        this.durationMs = source["durationMs"];
	        this.bodyJson = source["bodyJson"];
	        this.responseMetadata = source["responseMetadata"];
	        this.error = source["error"];
	    }
	}
	export class ListServicesResponse {
	    services: GrpcService[];

	    static createFrom(source: any = {}) {
	        return new ListServicesResponse(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.services = this.convertValues(source["services"], GrpcService);
	    }

		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class PickProtoFilesResponse {
	    paths: string[];

	    static createFrom(source: any = {}) {
	        return new PickProtoFilesResponse(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.paths = source["paths"];
	    }
	}
	export class PickProtoFolderResponse {
	    folder: string;
	    protoFiles: string[];

	    static createFrom(source: any = {}) {
	        return new PickProtoFolderResponse(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.folder = source["folder"];
	        this.protoFiles = source["protoFiles"];
	    }
	}
	export class SaveCollectionRequest {
	    name: string;
	    description: string;

	    static createFrom(source: any = {}) {
	        return new SaveCollectionRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.description = source["description"];
	    }
	}
	export class SaveCollectionRequestItemRequest {
	    collectionId: string;
	    name: string;
	    serverId: string;
	    serverName: string;
	    serverAddress: string;
	    serviceName: string;
	    methodName: string;
	    fullMethod: string;
	    requestJson: string;
	    requestMetadataJson: string;

	    static createFrom(source: any = {}) {
	        return new SaveCollectionRequestItemRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.collectionId = source["collectionId"];
	        this.name = source["name"];
	        this.serverId = source["serverId"];
	        this.serverName = source["serverName"];
	        this.serverAddress = source["serverAddress"];
	        this.serviceName = source["serviceName"];
	        this.methodName = source["methodName"];
	        this.fullMethod = source["fullMethod"];
	        this.requestJson = source["requestJson"];
	        this.requestMetadataJson = source["requestMetadataJson"];
	    }
	}
	export class SaveHistoryItemRequest {
	    serverId: string;
	    serverName: string;
	    serverAddress: string;
	    serviceName: string;
	    methodName: string;
	    fullMethod: string;
	    requestJson: string;
	    requestMetadataJson: string;
	    responseJson: string;
	    statusCode: string;
	    statusMessage?: string;
	    durationMs: number;
	    error?: string;

	    static createFrom(source: any = {}) {
	        return new SaveHistoryItemRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.serverId = source["serverId"];
	        this.serverName = source["serverName"];
	        this.serverAddress = source["serverAddress"];
	        this.serviceName = source["serviceName"];
	        this.methodName = source["methodName"];
	        this.fullMethod = source["fullMethod"];
	        this.requestJson = source["requestJson"];
	        this.requestMetadataJson = source["requestMetadataJson"];
	        this.responseJson = source["responseJson"];
	        this.statusCode = source["statusCode"];
	        this.statusMessage = source["statusMessage"];
	        this.durationMs = source["durationMs"];
	        this.error = source["error"];
	    }
	}
	export class SaveServerProfileRequest {
	    name: string;
	    address: string;
	    tlsEnabled: boolean;
	    reflectionEnabled: boolean;
	    protoFiles: string[];
	    protoFolders: string[];
	    metadataJson: string;

	    static createFrom(source: any = {}) {
	        return new SaveServerProfileRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.address = source["address"];
	        this.tlsEnabled = source["tlsEnabled"];
	        this.reflectionEnabled = source["reflectionEnabled"];
	        this.protoFiles = source["protoFiles"];
	        this.protoFolders = source["protoFolders"];
	        this.metadataJson = source["metadataJson"];
	    }
	}
	export class ServerProfile {
	    workspaceId: string;
	    id: string;
	    name: string;
	    address: string;
	    tlsEnabled: boolean;
	    reflectionEnabled: boolean;
	    protoFiles: string[];
	    protoFolders: string[];
	    metadataJson: string;

	    static createFrom(source: any = {}) {
	        return new ServerProfile(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.workspaceId = source["workspaceId"];
	        this.id = source["id"];
	        this.name = source["name"];
	        this.address = source["address"];
	        this.tlsEnabled = source["tlsEnabled"];
	        this.reflectionEnabled = source["reflectionEnabled"];
	        this.protoFiles = source["protoFiles"];
	        this.protoFolders = source["protoFolders"];
	        this.metadataJson = source["metadataJson"];
	    }
	}
	export class ValidateProtoSourcesRequest {
	    protoFiles: string[];
	    protoFolders: string[];

	    static createFrom(source: any = {}) {
	        return new ValidateProtoSourcesRequest(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.protoFiles = source["protoFiles"];
	        this.protoFolders = source["protoFolders"];
	    }
	}
	export class ValidateProtoSourcesResponse {
	    valid: boolean;
	    fileCount: number;
	    errors?: string[];

	    static createFrom(source: any = {}) {
	        return new ValidateProtoSourcesResponse(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.valid = source["valid"];
	        this.fileCount = source["fileCount"];
	        this.errors = source["errors"];
	    }
	}
	export class WorkspaceTransferResult {
	    path?: string;
	    serverCount: number;
	    collectionCount: number;
	    savedRequestCount: number;
	    skipped?: boolean;

	    static createFrom(source: any = {}) {
	        return new WorkspaceTransferResult(source);
	    }

	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.path = source["path"];
	        this.serverCount = source["serverCount"];
	        this.collectionCount = source["collectionCount"];
	        this.savedRequestCount = source["savedRequestCount"];
	        this.skipped = source["skipped"];
	    }
	}

}
