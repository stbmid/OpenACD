/* Functions and operations for the agents tab */

var agents = function(){
	return {}
}

agents.updateModule = function(subform){
	dojo.xhrPost({
		url:"agents/editmodules",
		handleAs:"json",
		form:subform,
		error:function(response, ioargs){
			console.log(response);
		},
		load:function(response, ioargs){
			console.log(response);
		}
	})
}

agents.getModules = function(targetform){
	dojo.xhrGet({
		url:"agents/getmodules",
		handleAs:"json",
		load:function(response, ioargs){
			targetform.setValues(response.result);
		}
	})
}

agents.store = new dojo.data.ItemFileReadStore({
	data:{
		"items":[]
	}
});

agents.model = new dijit.tree.ForestStoreModel({
	store: agents.store,
	labelAttr:"name",
	query:{"type":"profile"},
	childrenAttrs:["agents"],
	rootId:"agents",
	rootLabel:"Agents"
});

agents.init = function(){
	agents.store = new dojo.data.ItemFileWriteStore({
		url:"/agents"
	});
	agents.store.fetch();
	agents.model = new dijit.tree.ForestStoreModel({
		store: agents.store,
		labelAttr:"name",
		query:{"type":"profile"},
		childrenAttrs:["agents"],
		rootId:"agents",
		rootLabel:"Agents"
	});
}

agents.tree = false;

agents.refreshTree = function(targetnode){
	var parent = dojo.byId(targetnode).parentNode;
	//agents.store.fetch();
	agents.init();
	if(dijit.byId(agents.tree.id)){
		dijit.byId(agents.tree.id).destroy();
	};
	var n = dojo.doc.createElement('div');
	n.id = targetnode;
	parent.appendChild(n);
	agents.tree = new dijit.Tree({
		store: agents.store,
		model: agents.model,
		showRoot:false
	}, targetnode);
	dojo.publish("agents/tree/refreshed", []);
}

agents.updateProfile = function(submitForm, treenode){
	var values = dijit.byId(submitForm).getValues();
	var xhrurl = "/agents/" + values.oldname + "/update";
	dojo.xhrPost({
		url:xhrurl,
		handleAs:"json",
		form:submitForm,
		load:function(response, ioargs){
			agents.refreshTree(treenode);
		}
	});
}

agents.newProfile = function(submitForm, treenode){
	dojo.xhrPost({
		url:"/agents/newprofile",
		handleAs:"json",
		form:submitForm,
		load:function(response, ioargs){
			agents.refreshTree(treenode);
		}
	})
}