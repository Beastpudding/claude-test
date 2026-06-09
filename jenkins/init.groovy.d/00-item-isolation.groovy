// Jenkins Item 생성 listener — creator에게만 본인 Item 권한 자동 부여.
//
// Flow:
//   1. 사용자가 새 Item(Job/Folder/Pipeline) 생성
//   2. ItemListener.onCreated 발화 → 현재 인증된 사용자(creator) 확인
//   3. 그 Item에 AuthorizationMatrixProperty 추가:
//      - creator: 모든 Item 권한
//      - authenticated: 권한 없음 (다른 사용자 listing에서 자동 숨김)
//
// 결과: 각자 본인 Item만 보이고 편집/빌드 가능. admin은 Overall/Administer로 전체 보임.

import com.cloudbees.hudson.plugins.folder.AbstractFolder
import com.cloudbees.hudson.plugins.folder.properties.AuthorizationMatrixProperty as FolderAuthMatrix
import hudson.model.Item
import hudson.model.Job
import hudson.model.Run
import hudson.model.User
import hudson.model.listeners.ItemListener
import hudson.security.AuthorizationMatrixProperty as JobAuthMatrix
import jenkins.model.Jenkins
import org.jenkinsci.plugins.matrixauth.inheritance.NonInheritingStrategy

class IsolationListener extends ItemListener {
    @Override
    void onCreated(Item item) {
        def creator = User.current()
        if (creator == null) return
        def username = creator.id
        if (username == 'SYSTEM' || username == 'anonymous') return

        def perms = [
            Item.READ, Item.CONFIGURE, Item.BUILD, Item.DELETE,
            Item.CANCEL, Item.WORKSPACE, Item.DISCOVER, Item.MOVE,
            Run.UPDATE, Run.DELETE
        ]
        def grants = [:]
        for (p in perms) { grants.put(p, [username] as Set) }

        if (item instanceof AbstractFolder) {
            def prop = new FolderAuthMatrix(grants)
            prop.setInheritanceStrategy(new NonInheritingStrategy())
            item.addProperty(prop)
            item.save()
            println "[item-isolation] folder ${item.fullName} → ${username}"
        } else if (item instanceof Job) {
            def prop = new JobAuthMatrix(grants)
            prop.setInheritanceStrategy(new NonInheritingStrategy())
            item.addProperty(prop)
            item.save()
            println "[item-isolation] job ${item.fullName} → ${username}"
        }
    }
}

def list = Jenkins.instance.getExtensionList(ItemListener.class)
list.removeAll { it.class.name == IsolationListener.class.name }
list.add(new IsolationListener())
println "[item-isolation] listener registered (${list.size()} listeners total)"
